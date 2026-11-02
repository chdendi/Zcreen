import Foundation
import Cocoa
import CryptoKit

/// One capture of the current layout plus the AX element each window came from.
struct CapturedLayout {
    let snapshot: LayoutSnapshot
    /// Aligned by index with `snapshot.windows`; nil when the source element is unknown.
    let elements: [AXUIElement?]
}

/// What a finished restore actually achieved. Saves use it to keep windows that were not
/// put back from being written into the snapshot at the position macOS left them in.
struct RestoreOutcome {
    struct Drifted {
        let window: AXUIElement
        let saved: WindowSnapshot
        let frame: CGRect
    }

    struct Orphan {
        let window: AXUIElement
        let bundleId: String
        let frame: CGRect
    }

    let profileKey: String
    let placedCount: Int
    /// Moved, but the app ended up somewhere else.
    let drifted: [Drifted]
    /// Unmatched running windows of apps that still have unresolved saved entries.
    let orphans: [Orphan]
    /// Saved windows of running apps that were never placed.
    let unresolved: [WindowSnapshot]

    var isComplete: Bool { drifted.isEmpty && unresolved.isEmpty }
}

class LayoutSnapshotStore: ObservableObject {
    @Published private(set) var savedProfileCount: Int = 0

    private let snapshotDir: URL
    private var cache: [String: LayoutSnapshot] = [:]
    private weak var screenDetector: ScreenDetector?
    /// The in-flight restore, if any. Retry and verification closures only act while their
    /// run is still the active one, so a newer restore or a cancel silently ends older chains.
    private var activeRestore: RestoreRun?
    /// Per profile: the AX element each saved entry was captured from in this session.
    private var windowIdentities: [String: [(snapshot: WindowSnapshot, element: AXUIElement)]] = [:]
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void
    private let runningBundleIds: () -> Set<String>

    init(snapshotDirectory: URL? = nil, loadExisting: Bool = true, screenDetector: ScreenDetector? = nil,
         scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         },
         runningBundleIds: @escaping () -> Set<String> = {
             Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
         }) {
        self.scheduleAfter = scheduleAfter
        self.runningBundleIds = runningBundleIds
        let configDir = snapshotDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/zcreen/snapshots")
        self.snapshotDir = configDir
        self.screenDetector = screenDetector
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        if loadExisting {
            loadAll()
        }
    }

    /// Allow the store to be constructed before the orchestrator wires up the detector.
    func setScreenDetector(_ detector: ScreenDetector) {
        self.screenDetector = detector
    }

    @discardableResult
    func save(snapshot: LayoutSnapshot) -> Bool {
        let fileURL = snapshotFileLocation(for: snapshot.profileKey)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(snapshot)
            archiveCurrentVersion(profileKey: snapshot.profileKey, force: false)
            try data.write(to: fileURL, options: .atomic)
            cache[snapshot.profileKey] = snapshot
            savedProfileCount = cache.count
            Log.snapshot.info("Saved snapshot for '\(snapshot.profileLabel)' (\(snapshot.windows.count) windows)")
            return true
        } catch {
            Log.snapshot.error("Failed to save snapshot: \(error.localizedDescription)")
            return false
        }
    }

    func load(profileKey: String) -> LayoutSnapshot? {
        cache[profileKey] ?? migrateLegacySnapshot(profileKey: profileKey)
    }

    private func migrateLegacySnapshot(profileKey: String) -> LayoutSnapshot? {
        guard let screens = screenDetector?.screens, !screens.isEmpty,
              screens.map(\.uniqueKey).sorted().joined(separator: "+") == profileKey else { return nil }
        let legacyKeys = screens.map { "\($0.vendorID)-\($0.modelID)-\($0.serialNumber)" }
        // A zero serial number may have collapsed two identical displays in the old
        // format. Preserve that file rather than guessing which monitor it meant.
        guard Set(legacyKeys).count == screens.count,
              let old = cache[legacyKeys.sorted().joined(separator: "+")] else { return nil }
        let mapping = Dictionary(uniqueKeysWithValues: zip(legacyKeys, screens.map(\.uniqueKey)))
        let migrated = LayoutSnapshot(profileKey: profileKey, profileLabel: old.profileLabel,
            timestamp: old.timestamp, windows: old.windows.map { window in
                WindowSnapshot(bundleId: window.bundleId, appName: window.appName, windowTitle: window.windowTitle,
                    frame: window.frame, screenName: window.screenName,
                    screenKey: window.screenKey.flatMap { mapping[$0] ?? $0 }, relativeFrame: window.relativeFrame,
                    windowRole: window.windowRole, windowSubrole: window.windowSubrole)
            })
        guard save(snapshot: migrated) else { return nil }
        Log.snapshot.info("Migrated legacy snapshot to UUID profile; original file preserved")
        return migrated
    }

    func savedProfiles() -> [(key: String, label: String, windowCount: Int, date: Date)] {
        cache.values
            .sorted { $0.timestamp > $1.timestamp }
            .map { (key: $0.profileKey, label: $0.profileLabel, windowCount: $0.windows.count, date: $0.timestamp) }
    }

    func savedAppNames(for profileKey: String) -> [String] {
        guard let snapshot = cache[profileKey] else { return [] }
        var seen = Set<String>()
        return snapshot.windows.compactMap { w in
            guard !w.appName.isEmpty, seen.insert(w.appName).inserted else { return nil }
            return w.appName
        }
    }

    func snapshotFileURL(for profileKey: String) -> URL? {
        guard cache[profileKey] != nil else { return nil }
        let fileURL = snapshotFileLocation(for: profileKey)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    // MARK: - Capture

    func captureLayout(profileKey: String, profileLabel: String, windowManager: WindowManager,
                       screens: [ScreenInfo], excludeAppMatchers: [AppMatcher] = [],
                       windowFilter: WindowFilter) -> CapturedLayout {
        let allWindows = windowManager.getAllWindows(filter: windowFilter).filter {
            !isExcluded(bundleId: $0.bundleId, appName: $0.appName, excludeAppMatchers: excludeAppMatchers)
        }
        let pairs = allWindows.map { win -> (snapshot: WindowSnapshot, element: AXUIElement) in
            let screen = findScreen(for: win.frame, in: screens)
            let snapshot = WindowSnapshot(
                bundleId: win.bundleId ?? "",
                appName: win.appName,
                windowTitle: win.title,
                frame: WindowSnapshot.CodableRect(win.frame),
                screenName: screen?.name ?? "Unknown",
                screenKey: screen?.uniqueKey,
                relativeFrame: screen.flatMap { screen in
                    guard let screenFrame = CoordinateConverter.accessibilityScreenFrame(for: screen, screens: screens) else {
                        return nil
                    }
                    return WindowSnapshot.CodableRect.relative(from: win.frame, in: screenFrame)
                },
                windowRole: win.role,
                windowSubrole: win.subrole
            )
            return (snapshot, win.axWindow)
        }
        .sorted { Self.compareWindowSnapshots($0.snapshot, $1.snapshot) }

        return CapturedLayout(
            snapshot: LayoutSnapshot(profileKey: profileKey, profileLabel: profileLabel,
                                     timestamp: Date(), windows: pairs.map(\.snapshot)),
            elements: pairs.map { Optional($0.element) }
        )
    }

    func captureSnapshot(profileKey: String, profileLabel: String, windowManager: WindowManager,
                         screens: [ScreenInfo], excludeAppMatchers: [AppMatcher] = [],
                         windowFilter: WindowFilter) -> LayoutSnapshot {
        captureLayout(profileKey: profileKey, profileLabel: profileLabel, windowManager: windowManager,
                      screens: screens, excludeAppMatchers: excludeAppMatchers, windowFilter: windowFilter).snapshot
    }

    // MARK: - Window identity

    /// Remember which AX element each entry of `profileKey`'s snapshot came from, so a later
    /// restore in this session can pair them exactly instead of guessing by title and size.
    func rememberIdentities(profileKey: String, windows: [WindowSnapshot], elements: [AXUIElement?]) {
        windowIdentities[profileKey] = zip(windows, elements).compactMap { window, element in
            element.map { (snapshot: window, element: $0) }
        }
    }

    /// Known AX elements for `saved`, aligned by index; nil where none is known.
    func identityElements(for saved: [WindowSnapshot], profileKey: String) -> [AXUIElement?] {
        var available = windowIdentities[profileKey] ?? []
        return saved.map { window in
            guard let index = available.firstIndex(where: { $0.snapshot == window }) else { return nil }
            return available.remove(at: index).element
        }
    }

    // MARK: - Restore

    var isRestoreInFlight: Bool { activeRestore != nil }

    /// Stops the in-flight restore. Returns whether one was still placing or verifying windows.
    @discardableResult
    func cancelRestore() -> Bool {
        let wasRunning = activeRestore != nil
        activeRestore = nil
        return wasRunning
    }

    func restoreSnapshot(_ snapshot: LayoutSnapshot, windowManager: WindowManager,
                         excludeAppMatchers: [AppMatcher] = [], windowFilter: WindowFilter,
                         completion: ((RestoreOutcome) -> Void)? = nil) {
        cancelRestore()
        let savedWindows = snapshot.windows.filter {
            !isExcluded(bundleId: $0.bundleId, appName: $0.appName, excludeAppMatchers: excludeAppMatchers) &&
                windowFilter.allows(snapshot: $0)
        }
        let run = RestoreRun(profileKey: snapshot.profileKey, profileLabel: snapshot.profileLabel,
                             windowManager: windowManager, excludeAppMatchers: excludeAppMatchers,
                             windowFilter: windowFilter, pending: savedWindows, completion: completion)
        activeRestore = run
        restoreAttempt(run, attempt: 0)
    }

    private func restoreAttempt(_ run: RestoreRun, attempt: Int) {
        guard run === activeRestore else { return }
        let available = run.windowManager.getWindows(bundleIds: Set(run.pending.map(\.bundleId))).filter { window in
            run.windowFilter.allows(window: window) && !run.isCompleted(window.axWindow) &&
                !isExcluded(bundleId: window.bundleId, appName: window.appName,
                            excludeAppMatchers: run.excludeAppMatchers)
        }
        let currentScreens = currentScreensSnapshot()
        let activeApps = runningBundleIds()
        let savedByBundle = Dictionary(grouping: run.pending, by: \.bundleId)
        let runningByBundle = Dictionary(grouping: available, by: { $0.bundleId ?? "" })
        var stillPending: [WindowSnapshot] = []
        var requested = 0
        Log.snapshot.info("RESTORE: profile '\(run.profileLabel)', attempt \(attempt), \(run.pending.count) pending saved windows, \(available.count) available")

        for (bundleId, saved) in savedByBundle {
            let running = runningByBundle[bundleId] ?? []
            guard !running.isEmpty else {
                if activeApps.contains(bundleId) { stillPending.append(contentsOf: saved) }
                continue
            }
            let candidates = running.map { window -> WindowMatchCandidate in
                let screen = currentScreenContext(for: window.frame, in: currentScreens)
                return WindowMatchCandidate(title: window.title, frame: window.frame, screenName: screen.name,
                    screenKey: screen.key, role: window.role, subrole: window.subrole)
            }
            let assignments = WindowMatcher.match(
                saved: saved, running: candidates,
                savedElements: identityElements(for: saved, profileKey: run.profileKey),
                runningElements: running.map(\.axWindow)
            )
            let matchedSaved = Set(assignments.map(\.savedIndex))
            let matchedRunning = Set(assignments.map(\.runningIndex))
            for assignment in assignments.sorted(by: { $0.savedIndex < $1.savedIndex }) {
                let savedWindow = saved[assignment.savedIndex]
                let window = running[assignment.runningIndex]
                let target = savedWindow.resolvedFrame(using: currentScreens)
                let label = assignment.isIdentity ? "identity" : (assignment.isLowConfidence ? "low-confidence" : "matched")
                let name = savedWindow.windowTitle ?? savedWindow.appName
                run.markPlaced(window.axWindow)
                // Re-setting a frame the window already has still makes apps re-layout and flicker.
                if window.frame.isClose(to: target, tolerance: Constants.Restore.inPlaceTolerance) {
                    Log.snapshot.info("RESTORE: \(label) '\(name)' already in place")
                    continue
                }
                Log.snapshot.info("RESTORE: \(label) '\(name)' [score=\(assignment.score)] → \(target)")
                run.windowManager.moveWindow(window.axWindow, toFrame: target)
                run.moved.append((window: window.axWindow, saved: savedWindow, target: target))
                requested += 1
            }
            for (index, window) in running.enumerated() where !matchedRunning.contains(index) {
                run.noteOrphan(window)
            }
            if activeApps.contains(bundleId) {
                stillPending.append(contentsOf: saved.enumerated().filter { !matchedSaved.contains($0.offset) }.map(\.element))
            }
        }
        run.pending = stillPending
        Log.snapshot.info("RESTORE: requested \(requested) window moves; \(stillPending.count) windows pending")

        guard !stillPending.isEmpty, attempt < Constants.Timing.snapshotMaxRetries else {
            if !stillPending.isEmpty {
                Log.snapshot.warning("RESTORE: retry limit reached; \(stillPending.count) saved windows remain unmatched")
            }
            finishRestore(run)
            return
        }
        let delay = Constants.Timing.snapshotRetryBaseDelay * pow(2, Double(attempt))
        scheduleAfter(delay) { [weak self] in
            self?.restoreAttempt(run, attempt: attempt + 1)
        }
    }

    /// Re-reads moved windows once they had time to settle. Apps (and macOS itself, while a
    /// display finishes negotiating) sometimes move a window again right after we set it.
    private func finishRestore(_ run: RestoreRun) {
        guard run === activeRestore else { return }
        guard !run.moved.isEmpty else {
            completeRestore(run, drifted: [])
            return
        }
        scheduleAfter(Constants.Timing.restoreVerifyDelay) { [weak self] in
            guard let self, run === self.activeRestore else { return }
            var drifted: [RestoreOutcome.Drifted] = []
            for move in run.moved {
                guard let actual = run.windowManager.frame(of: move.window),
                      !actual.isClose(to: move.target, tolerance: Constants.Restore.driftTolerance)
                else { continue }
                let name = move.saved.windowTitle ?? move.saved.appName
                Log.snapshot.info("RESTORE: '\(name)' drifted to \(actual); re-applying \(move.target)")
                run.windowManager.moveWindow(move.window, toFrame: move.target)
                if let after = run.windowManager.frame(of: move.window),
                   !after.isClose(to: move.target, tolerance: Constants.Restore.driftTolerance) {
                    drifted.append(.init(window: move.window, saved: move.saved, frame: after))
                }
            }
            self.completeRestore(run, drifted: drifted)
        }
    }

    private func completeRestore(_ run: RestoreRun, drifted: [RestoreOutcome.Drifted]) {
        activeRestore = nil
        let unresolvedBundles = Set(run.pending.map(\.bundleId))
        let orphans = run.orphans
            .filter { unresolvedBundles.contains($0.bundleId) }
            .map { orphan in
                RestoreOutcome.Orphan(window: orphan.window, bundleId: orphan.bundleId,
                                      frame: run.windowManager.frame(of: orphan.window) ?? orphan.frame)
            }
        let outcome = RestoreOutcome(profileKey: run.profileKey, placedCount: run.placedCount - drifted.count,
                                     drifted: drifted, orphans: orphans, unresolved: run.pending)
        if outcome.isComplete {
            Log.snapshot.info("RESTORE: finished for '\(run.profileLabel)' (\(outcome.placedCount) windows placed)")
        } else {
            Log.snapshot.warning(
                "RESTORE: finished for '\(run.profileLabel)' with \(drifted.count) drifted and "
                + "\(run.pending.count) unresolved windows; their saved positions stay protected until moved by the user"
            )
        }
        run.completion?(outcome)
    }

    private func isExcluded(bundleId: String?, appName: String?, excludeAppMatchers: [AppMatcher]) -> Bool {
        excludeAppMatchers.contains { $0.matches(bundleId: bundleId, appName: appName) }
    }

    // MARK: - History

    /// Copies the current file for `profileKey` into `history/<hash>/` before it is replaced,
    /// so one bad save can be rolled back by hand. Automatic overwrites are archived at most
    /// once per `minArchiveInterval`; `force` archives regardless (manual saves).
    func archiveCurrentVersion(profileKey: String, force: Bool) {
        let source = snapshotFileLocation(for: profileKey)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: source.path) else { return }
        let directory = historyDirectory(for: profileKey)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var versions = historyVersions(in: directory)
            if !force, let newest = versions.last,
               let date = try? newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) < Constants.SnapshotHistory.minArchiveInterval {
                return
            }
            let destination = directory.appendingPathComponent("\(Self.historyFormatter.string(from: Date())).json")
            guard !fileManager.fileExists(atPath: destination.path) else { return }
            try fileManager.copyItem(at: source, to: destination)
            versions.append(destination)
            for stale in versions.dropLast(Constants.SnapshotHistory.maxVersions) {
                try? fileManager.removeItem(at: stale)
            }
        } catch {
            Log.snapshot.warning("Could not archive previous snapshot: \(error.localizedDescription)")
        }
    }

    func historyDirectory(for profileKey: String) -> URL {
        snapshotDir.appendingPathComponent("history", isDirectory: true)
            .appendingPathComponent(fileNameHash(profileKey), isDirectory: true)
    }

    private func historyVersions(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        // Timestamped names sort chronologically.
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static let historyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    // MARK: - Private

    private func loadAll() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: snapshotDir, includingPropertiesForKeys: nil)
        else { return }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for file in files where file.pathExtension == "json" {
            if let data = try? Data(contentsOf: file),
               let snapshot = try? decoder.decode(LayoutSnapshot.self, from: data) {
                cache[snapshot.profileKey] = snapshot
            }
        }
        savedProfileCount = cache.count
        Log.snapshot.info("Loaded \(self.cache.count) cached snapshots")
    }

    private func snapshotFileLocation(for profileKey: String) -> URL {
        snapshotDir.appendingPathComponent("\(fileNameHash(profileKey)).json")
    }

    /// SHA256 hash of profile key → short hex string for filename
    private func fileNameHash(_ key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func findScreen(for windowFrame: CGRect, in screens: [ScreenInfo]) -> ScreenInfo? {
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return CoordinateConverter.screenContainingAccessibilityPoint(center, in: screens)
    }

    /// Resolve the current screen for a window frame, returning both display name and persistent key.
    private func currentScreenContext(for frame: CGRect, in screens: [ScreenInfo]) -> (name: String, key: String?) {
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let screen = CoordinateConverter.screenContainingAccessibilityPoint(center, in: screens) {
            return (screen.name, screen.uniqueKey)
        }
        return ("Unknown", nil)
    }

    /// Prefer the injected `ScreenDetector` (single source of truth) and fall back to a
    /// directly-built list from `NSScreen.screens` for tests / standalone usage.
    private func currentScreensSnapshot() -> [ScreenInfo] {
        if let detectorScreens = screenDetector?.screens, !detectorScreens.isEmpty {
            return detectorScreens
        }
        return ScreenDetector.currentSystemScreens()
    }

    /// Canonical ordering for snapshot windows, shared with merge logic so the
    /// "unchanged" comparison stays stable regardless of how a window list was built.
    static func sortedForSnapshot(_ windows: [WindowSnapshot]) -> [WindowSnapshot] {
        windows.sorted(by: compareWindowSnapshots)
    }

    static func compareWindowSnapshots(_ lhs: WindowSnapshot, _ rhs: WindowSnapshot) -> Bool {
        // Lexicographic order over a stable key tuple. Split into two tuples because Swift only
        // synthesizes Comparable for tuples up to 6 elements.
        let lKey1 = (lhs.bundleId, lhs.appName, lhs.windowTitle ?? "", lhs.windowRole ?? "", lhs.windowSubrole ?? "", lhs.screenName)
        let rKey1 = (rhs.bundleId, rhs.appName, rhs.windowTitle ?? "", rhs.windowRole ?? "", rhs.windowSubrole ?? "", rhs.screenName)
        if lKey1 != rKey1 { return lKey1 < rKey1 }
        return (lhs.frame.x, lhs.frame.y, lhs.frame.width, lhs.frame.height) <
               (rhs.frame.x, rhs.frame.y, rhs.frame.width, rhs.frame.height)
    }
}

/// Mutable state of one restore chain (initial attempt, retries and verification).
private final class RestoreRun {
    let profileKey: String
    let profileLabel: String
    let windowManager: WindowManager
    let excludeAppMatchers: [AppMatcher]
    let windowFilter: WindowFilter
    let completion: ((RestoreOutcome) -> Void)?
    var pending: [WindowSnapshot]
    var moved: [(window: AXUIElement, saved: WindowSnapshot, target: CGRect)] = []
    private(set) var placedCount = 0
    private(set) var orphans: [RestoreOutcome.Orphan] = []
    private var placed: [AXUIElement] = []

    init(profileKey: String, profileLabel: String, windowManager: WindowManager,
         excludeAppMatchers: [AppMatcher], windowFilter: WindowFilter,
         pending: [WindowSnapshot], completion: ((RestoreOutcome) -> Void)?) {
        self.profileKey = profileKey
        self.profileLabel = profileLabel
        self.windowManager = windowManager
        self.excludeAppMatchers = excludeAppMatchers
        self.windowFilter = windowFilter
        self.pending = pending
        self.completion = completion
    }

    func isCompleted(_ window: AXUIElement) -> Bool {
        placed.contains { CFEqual($0, window) }
    }

    func markPlaced(_ window: AXUIElement) {
        placed.append(window)
        placedCount += 1
        orphans.removeAll { CFEqual($0.window, window) }
    }

    func noteOrphan(_ window: WindowManager.WindowInfo) {
        orphans.removeAll { CFEqual($0.window, window.axWindow) }
        orphans.append(.init(window: window.axWindow, bundleId: window.bundleId ?? "", frame: window.frame))
    }
}

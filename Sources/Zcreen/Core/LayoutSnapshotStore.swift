import Foundation
import Cocoa
import CryptoKit

class LayoutSnapshotStore: ObservableObject {
    @Published private(set) var savedProfileCount: Int = 0

    private let snapshotDir: URL
    private var cache: [String: LayoutSnapshot] = [:]
    private weak var screenDetector: ScreenDetector?
    /// Generation token for in-flight restore retry chains. Each top-level
    /// `restoreSnapshot` call bumps this; queued retry closures check that the
    /// generation still matches before running, so a fresh restore (e.g. triggered
    /// by another screen change while displays were still settling) cancels the
    /// previous chain instead of stacking moves on top.
    private var restoreGeneration: UInt64 = 0

    init(snapshotDirectory: URL? = nil, loadExisting: Bool = true, screenDetector: ScreenDetector? = nil) {
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

    func save(snapshot: LayoutSnapshot) {
        cache[snapshot.profileKey] = snapshot
        savedProfileCount = cache.count

        let fileURL = snapshotDir.appendingPathComponent("\(fileNameHash(snapshot.profileKey)).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(snapshot)
            try data.write(to: fileURL)
            Log.snapshot.info("Saved snapshot for '\(snapshot.profileLabel)' (\(snapshot.windows.count) windows)")
        } catch {
            Log.snapshot.error("Failed to save snapshot: \(error.localizedDescription)")
        }
    }

    func load(profileKey: String) -> LayoutSnapshot? {
        cache[profileKey]
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

    func captureSnapshot(profileKey: String, profileLabel: String, windowManager: WindowManager,
                         screens: [ScreenInfo], excludeAppMatchers: [AppMatcher] = [],
                         windowFilter: WindowFilter) -> LayoutSnapshot {
        let allWindows = windowManager.getAllWindows(filter: windowFilter).filter {
            !isExcluded(
                bundleId: $0.bundleId,
                appName: $0.appName,
                excludeBundleIds: [],
                excludeAppMatchers: excludeAppMatchers
            )
        }
        let windowSnapshots = allWindows.map { win -> WindowSnapshot in
            let screen = findScreen(for: win.frame, in: screens)
            return WindowSnapshot(
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
        }
        .sorted(by: Self.compareWindowSnapshots)

        return LayoutSnapshot(
            profileKey: profileKey,
            profileLabel: profileLabel,
            timestamp: Date(),
            windows: windowSnapshots
        )
    }

    func restoreSnapshot(_ snapshot: LayoutSnapshot, windowManager: WindowManager, excludeBundleIds: Set<String>,
                         excludeAppMatchers: [AppMatcher] = [], windowFilter: WindowFilter) {
        restoreGeneration &+= 1
        let generation = restoreGeneration
        let missed = doRestore(snapshot: snapshot, windowManager: windowManager,
                               excludeBundleIds: excludeBundleIds,
                               excludeAppMatchers: excludeAppMatchers,
                               windowFilter: windowFilter)

        if !missed.isEmpty {
            scheduleRetry(snapshot: snapshot, windowManager: windowManager,
                          excludeBundleIds: excludeBundleIds,
                          excludeAppMatchers: excludeAppMatchers,
                          windowFilter: windowFilter,
                          missed: missed, attempt: 1, generation: generation)
        }
    }

    // MARK: - Exponential backoff retry

    private func scheduleRetry(snapshot: LayoutSnapshot, windowManager: WindowManager,
                               excludeBundleIds: Set<String>, excludeAppMatchers: [AppMatcher],
                               windowFilter: WindowFilter,
                               missed: [String], attempt: Int, generation: UInt64) {
        let maxRetries = Constants.Timing.snapshotMaxRetries
        guard attempt <= maxRetries else {
            Log.snapshot.info("RESTORE: gave up after \(maxRetries) retries, \(missed.count) apps still inaccessible")
            return
        }
        // A newer restore has started — abandon this chain instead of fighting it.
        guard generation == restoreGeneration else {
            Log.snapshot.info("RESTORE: aborting stale retry chain (gen=\(generation) current=\(self.restoreGeneration))")
            return
        }

        // Exponential backoff: 1s → 2s → 4s
        let delay = Constants.Timing.snapshotRetryBaseDelay * pow(2.0, Double(attempt - 1))
        Log.snapshot.info("RESTORE: \(missed.count) apps missed, retry \(attempt)/\(maxRetries) in \(delay)s...")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard generation == self.restoreGeneration else {
                Log.snapshot.info("RESTORE: skipping retry, superseded by gen=\(self.restoreGeneration)")
                return
            }
            let stillMissed = self.doRestore(snapshot: snapshot, windowManager: windowManager,
                                             excludeBundleIds: excludeBundleIds,
                                             excludeAppMatchers: excludeAppMatchers,
                                             windowFilter: windowFilter)
            if !stillMissed.isEmpty {
                self.scheduleRetry(snapshot: snapshot, windowManager: windowManager,
                                   excludeBundleIds: excludeBundleIds,
                                   excludeAppMatchers: excludeAppMatchers,
                                   windowFilter: windowFilter,
                                   missed: stillMissed, attempt: attempt + 1,
                                   generation: generation)
            }
        }
    }

    /// Returns bundle IDs of apps that were in snapshot but couldn't be found/moved.
    @discardableResult
    private func doRestore(snapshot: LayoutSnapshot, windowManager: WindowManager,
                           excludeBundleIds: Set<String>, excludeAppMatchers: [AppMatcher],
                           windowFilter: WindowFilter) -> [String] {
        let allWindows = windowManager.getAllWindows(filter: windowFilter)
        let currentScreens = currentScreensSnapshot()
        Log.snapshot.info("RESTORE: snapshot has \(snapshot.windows.count) saved, \(allWindows.count) running")

        var savedByBundle: [String: [WindowSnapshot]] = [:]
        for w in snapshot.windows where !isExcluded(
            bundleId: w.bundleId,
            appName: w.appName,
            excludeBundleIds: excludeBundleIds,
            excludeAppMatchers: excludeAppMatchers
        ) && windowFilter.allows(snapshot: w) {
            savedByBundle[w.bundleId, default: []].append(w)
        }

        var runningByBundle: [String: [WindowManager.WindowInfo]] = [:]
        for w in allWindows {
            let bid = w.bundleId ?? ""
            if !isExcluded(
                bundleId: bid,
                appName: w.appName,
                excludeBundleIds: excludeBundleIds,
                excludeAppMatchers: excludeAppMatchers
            ) {
                runningByBundle[bid, default: []].append(w)
            }
        }

        var restored = 0
        var missed: [String] = []

        for (bundleId, savedWindows) in savedByBundle {
            guard let runningWindows = runningByBundle[bundleId] else {
                if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == bundleId }) {
                    missed.append(bundleId)
                    Log.snapshot.info("RESTORE: \(savedWindows.first?.appName ?? bundleId) — running but AX returned 0 windows")
                }
                continue
            }

            let candidates = runningWindows.map { running -> WindowMatchCandidate in
                let screen = currentScreenContext(for: running.frame, in: currentScreens)
                return WindowMatchCandidate(
                    title: running.title,
                    frame: running.frame,
                    screenName: screen.name,
                    screenKey: screen.key,
                    role: running.role,
                    subrole: running.subrole
                )
            }
            let assignments = WindowMatcher
                .match(saved: savedWindows, running: candidates)
                .sorted { $0.savedIndex < $1.savedIndex }

            for assignment in assignments {
                let savedWin = savedWindows[assignment.savedIndex]
                let runningWin = runningWindows[assignment.runningIndex]
                let target = savedWin.resolvedFrame(using: currentScreens)
                let confidence = assignment.isLowConfidence ? "low-confidence" : "matched"
                let titleLabel = savedWin.windowTitle?.isEmpty == false
                    ? savedWin.windowTitle!
                    : savedWin.appName

                Log.snapshot.info("RESTORE: \(confidence) '\(titleLabel)' [score=\(assignment.score)] → (\(Int(target.origin.x)),\(Int(target.origin.y)),\(Int(target.width))x\(Int(target.height)))")
                windowManager.moveWindow(runningWin.axWindow, toFrame: target)
                restored += 1
            }

            if assignments.count < savedWindows.count {
                let unmatchedCount = savedWindows.count - assignments.count
                Log.snapshot.info("RESTORE: \(savedWindows.first?.appName ?? bundleId) has \(unmatchedCount) saved windows without running match")
            }
        }

        Log.snapshot.info("RESTORE: moved \(restored) windows for '\(snapshot.profileLabel)'")
        return missed
    }

    private func isExcluded(bundleId: String?, appName: String?, excludeBundleIds: Set<String>,
                            excludeAppMatchers: [AppMatcher]) -> Bool {
        if let bundleId, excludeBundleIds.contains(bundleId) {
            return true
        }
        return excludeAppMatchers.contains { $0.matches(bundleId: bundleId, appName: appName) }
    }

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
        return detectCurrentScreens()
    }

    private func detectCurrentScreens() -> [ScreenInfo] {
        NSScreen.screens.compactMap { screen in
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return ScreenInfo(
                displayID: displayID,
                name: screen.localizedName,
                frame: screen.frame,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                position: .single,
                vendorID: CGDisplayVendorNumber(displayID),
                modelID: CGDisplayModelNumber(displayID),
                serialNumber: CGDisplaySerialNumber(displayID)
            )
        }
    }

    /// Canonical ordering for snapshot windows, shared with merge logic so the
    /// "unchanged" comparison stays stable regardless of how a window list was built.
    static func sortedForSnapshot(_ windows: [WindowSnapshot]) -> [WindowSnapshot] {
        windows.sorted(by: compareWindowSnapshots)
    }

    private static func compareWindowSnapshots(_ lhs: WindowSnapshot, _ rhs: WindowSnapshot) -> Bool {
        // Lexicographic order over a stable key tuple. Split into two tuples because Swift only
        // synthesizes Comparable for tuples up to 6 elements.
        let lKey1 = (lhs.bundleId, lhs.appName, lhs.windowTitle ?? "", lhs.windowRole ?? "", lhs.windowSubrole ?? "", lhs.screenName)
        let rKey1 = (rhs.bundleId, rhs.appName, rhs.windowTitle ?? "", rhs.windowRole ?? "", rhs.windowSubrole ?? "", rhs.screenName)
        if lKey1 != rKey1 { return lKey1 < rKey1 }
        return (lhs.frame.x, lhs.frame.y, lhs.frame.width, lhs.frame.height) <
               (rhs.frame.x, rhs.frame.y, rhs.frame.width, rhs.frame.height)
    }
}

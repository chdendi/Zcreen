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
        let fileURL = snapshotDir.appendingPathComponent("\(fileNameHash(snapshot.profileKey)).json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(snapshot)
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
        let fileURL = snapshotDir.appendingPathComponent("\(fileNameHash(profileKey)).json")
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
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

    func cancelRestore() { restoreGeneration &+= 1 }

    func restoreSnapshot(_ snapshot: LayoutSnapshot, windowManager: WindowManager, excludeBundleIds: Set<String>,
                         excludeAppMatchers: [AppMatcher] = [], windowFilter: WindowFilter) {
        cancelRestore()
        restorePending(snapshot: snapshot, windowManager: windowManager, excludeBundleIds: excludeBundleIds,
                       excludeAppMatchers: excludeAppMatchers, windowFilter: windowFilter,
                       completedWindows: [], attempt: 0, generation: restoreGeneration)
    }

    private func restorePending(snapshot: LayoutSnapshot, windowManager: WindowManager,
                                excludeBundleIds: Set<String>, excludeAppMatchers: [AppMatcher],
                                windowFilter: WindowFilter, completedWindows: [AXUIElement],
                                attempt: Int, generation: UInt64) {
        guard generation == restoreGeneration else { return }
        let allWindows = windowManager.getAllWindows(filter: windowFilter).filter { window in
            !completedWindows.contains { CFEqual($0, window.axWindow) } &&
                !isExcluded(bundleId: window.bundleId, appName: window.appName,
                            excludeBundleIds: excludeBundleIds, excludeAppMatchers: excludeAppMatchers)
        }
        let currentScreens = currentScreensSnapshot()
        let activeApps = runningBundleIds()
        let savedWindows = snapshot.windows.filter {
            !isExcluded(bundleId: $0.bundleId, appName: $0.appName,
                        excludeBundleIds: excludeBundleIds, excludeAppMatchers: excludeAppMatchers) &&
                windowFilter.allows(snapshot: $0)
        }
        let savedByBundle = Dictionary(grouping: savedWindows, by: \.bundleId)
        let runningByBundle = Dictionary(grouping: allWindows, by: { $0.bundleId ?? "" })
        var pending: [WindowSnapshot] = []
        var completed = completedWindows
        var requested = 0
        Log.snapshot.info("RESTORE: profile '\(snapshot.profileLabel)', attempt \(attempt), \(savedWindows.count) pending saved windows, \(allWindows.count) available")

        for (bundleId, saved) in savedByBundle {
            let running = runningByBundle[bundleId] ?? []
            guard !running.isEmpty else {
                if activeApps.contains(bundleId) { pending.append(contentsOf: saved) }
                continue
            }
            let candidates = running.map { window -> WindowMatchCandidate in
                let screen = currentScreenContext(for: window.frame, in: currentScreens)
                return WindowMatchCandidate(title: window.title, frame: window.frame, screenName: screen.name,
                    screenKey: screen.key, role: window.role, subrole: window.subrole)
            }
            let assignments = WindowMatcher.match(saved: saved, running: candidates)
            let matched = Set(assignments.map(\.savedIndex))
            for assignment in assignments.sorted(by: { $0.savedIndex < $1.savedIndex }) {
                let savedWindow = saved[assignment.savedIndex]
                let target = savedWindow.resolvedFrame(using: currentScreens)
                let window = running[assignment.runningIndex].axWindow
                let confidence = assignment.isLowConfidence ? "low-confidence" : "matched"
                Log.snapshot.info("RESTORE: \(confidence) '\(savedWindow.windowTitle ?? savedWindow.appName)' [score=\(assignment.score)] → \(target)")
                windowManager.moveWindow(window, toFrame: target)
                completed.append(window)
                requested += 1
            }
            if activeApps.contains(bundleId) {
                pending.append(contentsOf: saved.enumerated().filter { !matched.contains($0.offset) }.map(\.element))
            }
        }
        Log.snapshot.info("RESTORE: requested \(requested) window moves; \(pending.count) windows pending")
        guard !pending.isEmpty else { return }
        guard attempt < Constants.Timing.snapshotMaxRetries else {
            Log.snapshot.warning("RESTORE: retry limit reached; \(pending.count) saved windows remain unmatched")
            return
        }
        let remaining = LayoutSnapshot(profileKey: snapshot.profileKey, profileLabel: snapshot.profileLabel,
                                       timestamp: snapshot.timestamp, windows: pending)
        let delay = Constants.Timing.snapshotRetryBaseDelay * pow(2, Double(attempt))
        scheduleAfter(delay) { [weak self] in
            self?.restorePending(snapshot: remaining, windowManager: windowManager,
                excludeBundleIds: excludeBundleIds, excludeAppMatchers: excludeAppMatchers,
                windowFilter: windowFilter, completedWindows: completed, attempt: attempt + 1,
                generation: generation)
        }
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

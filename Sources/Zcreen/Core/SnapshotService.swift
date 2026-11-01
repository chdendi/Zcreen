import ApplicationServices
import Foundation

final class SnapshotService {
    enum Trigger: String {
        case manual
        case periodic
        case snapBar = "snap_bar"
        case screenChange = "screen_change"
        case screenWillChange = "screen_will_change"
        case appLaunch = "app_launch"
        case suspend

        var logLabel: String { rawValue }
    }

    enum SaveResult {
        case saved(windowCount: Int)
        case noWindows
        case unchanged
        /// The capture was thrown away because displays changed while it ran.
        case discarded
        /// Skipped because a restore is still placing windows.
        case deferred
        case failed

        var statusMessage: String? {
            switch self {
            case let .saved(windowCount):
                return "Saved layout (\(windowCount) windows)"
            case .noWindows:
                return "No windows available to save"
            case .unchanged, .discarded, .deferred:
                return nil
            case .failed:
                return "Could not save layout. Check the logs and retry."
            }
        }
    }

    enum RestoreResult {
        case restored(profileLabel: String)
        case missing(profileLabel: String)

        var statusMessage: String {
            switch self {
            case let .restored(profileLabel):
                return "Restoring layout for \(profileLabel)"
            case let .missing(profileLabel):
                return "No saved layout for \(profileLabel)"
            }
        }
    }

    /// Windows an automatic restore could not put back. Until the user moves them, saves keep
    /// their saved slots instead of recording where macOS happened to leave them.
    private struct RestoreGuard {
        struct Protected {
            let window: AXUIElement
            let bundleId: String
            let baseline: CGRect
            /// The saved entry a drifted window belongs to; nil for unmatched windows.
            let saved: WindowSnapshot?
        }

        let profileKey: String
        var protected: [Protected]
        var carried: [WindowSnapshot]
        /// Carried entries without protected windows (an app that has not reopened a window
        /// yet) are kept only until this date.
        let expiresAt: Date
    }

    private let screenSession: ScreenSessionService
    private let configManager: ConfigManager
    private let windowManager: WindowManager
    private let snapshotStore: LayoutSnapshotStore
    private let now: () -> Date
    private var restoreGuard: RestoreGuard?

    init(screenSession: ScreenSessionService,
         configManager: ConfigManager,
         windowManager: WindowManager,
         snapshotStore: LayoutSnapshotStore,
         now: @escaping () -> Date = Date.init) {
        self.screenSession = screenSession
        self.configManager = configManager
        self.windowManager = windowManager
        self.snapshotStore = snapshotStore
        self.now = now
    }

    /// - Parameter validate: Checked after capturing; returning false discards the capture.
    func saveCurrentLayout(trigger: Trigger, force: Bool, validate: (() -> Bool)? = nil) -> SaveResult {
        if !force, snapshotStore.isRestoreInFlight {
            Log.snapshot.info("Skipped snapshot save [\(trigger.logLabel)] while a restore is still placing windows")
            return .deferred
        }

        let configuration = configManager.configuration
        let captured = snapshotStore.captureLayout(
            profileKey: screenSession.currentProfileKey,
            profileLabel: screenSession.currentProfileLabel,
            windowManager: windowManager,
            screens: screenSession.currentScreens,
            windowFilter: WindowFilter(configuration: configuration)
        )

        if let validate, !validate() {
            Log.snapshot.warning("Discarded snapshot capture [\(trigger.logLabel)]: displays changed while capturing")
            return .discarded
        }

        if force { restoreGuard = nil }
        let pairs = guardedWindows(in: captured).sorted { LayoutSnapshotStore.compareWindowSnapshots($0.window, $1.window) }
        let effective = LayoutSnapshot(
            profileKey: captured.snapshot.profileKey,
            profileLabel: captured.snapshot.profileLabel,
            timestamp: captured.snapshot.timestamp,
            windows: pairs.map(\.window)
        )

        let existing = snapshotStore.load(profileKey: effective.profileKey)
        let snapshot = merging(captured: effective, into: existing)

        // Empty AX captures cannot erase saved positions. Explicit exclusions may
        // still remove old entries, even when every current app is excluded.
        if captured.snapshot.windows.isEmpty, existing == nil || existing?.windows == snapshot.windows {
            Log.snapshot.info("Skipped snapshot save [\(trigger.logLabel)] because no windows were captured")
            return .noWindows
        }

        let rememberIdentities = { [snapshotStore] in
            snapshotStore.rememberIdentities(profileKey: effective.profileKey,
                                             windows: pairs.map(\.window), elements: pairs.map(\.element))
        }

        if !force,
           let existing,
           existing.windows == snapshot.windows {
            rememberIdentities()
            Log.snapshot.info("Skipped snapshot save [\(trigger.logLabel)] because layout is unchanged")
            return .unchanged
        }

        // A manual save is the user's checkpoint: keep both the layout it replaces and the
        // new one in history, regardless of how recently automatic saves were archived.
        if trigger == .manual {
            snapshotStore.archiveCurrentVersion(profileKey: snapshot.profileKey, force: true)
        }
        guard snapshotStore.save(snapshot: snapshot) else { return .failed }
        if trigger == .manual {
            snapshotStore.archiveCurrentVersion(profileKey: snapshot.profileKey, force: true)
        }
        rememberIdentities()
        Log.snapshot.info("Saved snapshot [\(trigger.logLabel)] for '\(snapshot.profileLabel)'")
        return .saved(windowCount: snapshot.windows.count)
    }

    /// Applies the restore guard to a capture: protected windows the user has not touched are
    /// left out and their saved slots carried over instead. Carried entries have no element.
    private func guardedWindows(in captured: CapturedLayout) -> [(window: WindowSnapshot, element: AXUIElement?)] {
        let pairs = captured.snapshot.windows.enumerated().map { index, window in
            (window: window, element: index < captured.elements.count ? captured.elements[index] : nil)
        }
        guard var guardState = restoreGuard, guardState.profileKey == captured.snapshot.profileKey else {
            return pairs
        }

        let capturedBundles = Set(captured.snapshot.windows.map(\.bundleId))
        var kept: [(window: WindowSnapshot, element: AXUIElement?)] = []
        var remaining = guardState.protected
        var stillProtected: [RestoreGuard.Protected] = []

        for pair in pairs {
            guard let element = pair.element,
                  let index = remaining.firstIndex(where: { CFEqual($0.window, element) }) else {
                kept.append(pair)
                continue
            }
            let protected = remaining.remove(at: index)
            if pair.window.frame.cgRect.isClose(to: protected.baseline, tolerance: Constants.Restore.inPlaceTolerance) {
                stillProtected.append(protected)
                continue
            }
            // Moved since the restore finished: the user placed it, so it speaks for itself.
            kept.append(pair)
            if let saved = protected.saved, let carriedIndex = guardState.carried.firstIndex(of: saved) {
                guardState.carried.remove(at: carriedIndex)
            }
            Log.snapshot.info("Restore guard: '\(pair.window.windowTitle ?? pair.window.appName)' was moved; saving its new position")
        }
        // Protected windows missing from a capture that still contains their app were closed.
        // If the whole app is missing, AX probably returned nothing this time; keep waiting.
        stillProtected += remaining.filter { !capturedBundles.contains($0.bundleId) }
        guardState.protected = stillProtected

        if stillProtected.isEmpty, guardState.carried.isEmpty || now() >= guardState.expiresAt {
            Log.snapshot.info("Restore guard released for '\(captured.snapshot.profileLabel)'")
            restoreGuard = nil
            return kept
        }
        restoreGuard = guardState

        // Only stand in for apps present in this capture; for absent apps the regular merge
        // already keeps every saved entry.
        let filter = WindowFilter(configuration: configManager.configuration)
        let carried = guardState.carried.filter { capturedBundles.contains($0.bundleId) && filter.allows(snapshot: $0) }
        return kept + carried.map { (window: $0, element: nil) }
    }

    private func installRestoreGuard(from outcome: RestoreOutcome) {
        guard !outcome.isComplete else {
            restoreGuard = nil
            return
        }
        let protected = outcome.orphans.map {
            RestoreGuard.Protected(window: $0.window, bundleId: $0.bundleId, baseline: $0.frame, saved: nil)
        } + outcome.drifted.map {
            RestoreGuard.Protected(window: $0.window, bundleId: $0.saved.bundleId, baseline: $0.frame, saved: $0.saved)
        }
        restoreGuard = RestoreGuard(
            profileKey: outcome.profileKey,
            protected: protected,
            carried: outcome.unresolved + outcome.drifted.map(\.saved),
            expiresAt: now().addingTimeInterval(Constants.Timing.restoreGuardLifetime)
        )
        Log.snapshot.info("Restore guard: protecting \(outcome.unresolved.count + outcome.drifted.count) saved windows and \(protected.count) unplaced windows")
    }

    /// AX occasionally returns zero windows for individual apps (busy, mid-launch,
    /// lock-screen edge). Overwriting the stored snapshot with such a capture would
    /// permanently lose those apps' saved positions, so entries for apps that exist
    /// in the stored snapshot but are entirely absent from this capture are carried
    /// over. Apps present in the capture are always taken as-is.
    private func merging(captured: LayoutSnapshot, into existing: LayoutSnapshot?) -> LayoutSnapshot {
        guard let existing else { return captured }

        let capturedBundleIds = Set(captured.windows.map(\.bundleId))
        let filter = WindowFilter(configuration: configManager.configuration)
        let preserved = existing.windows.filter { window in
            !capturedBundleIds.contains(window.bundleId) && filter.allows(snapshot: window)
        }
        guard !preserved.isEmpty else { return captured }

        Log.snapshot.info("Snapshot merge preserved \(preserved.count) windows from apps missing in this capture")
        return LayoutSnapshot(
            profileKey: captured.profileKey,
            profileLabel: captured.profileLabel,
            timestamp: captured.timestamp,
            windows: LayoutSnapshotStore.sortedForSnapshot(captured.windows + preserved)
        )
    }

    func restoreCurrentLayout() -> RestoreResult {
        restoreLayout(
            profileKey: screenSession.currentProfileKey,
            profileLabel: screenSession.currentProfileLabel,
            successLogMessage: { snapshot in
                "Manual restore for '\(snapshot.profileLabel)'"
            }
        )
    }

    func restoreLayout(profileKey: String, profileLabel: String) -> RestoreResult {
        restoreLayout(
            profileKey: profileKey,
            profileLabel: profileLabel,
            successLogMessage: { snapshot in
                "Requested layout restore for '\(snapshot.profileLabel)' (\(snapshot.windows.count) saved windows)"
            }
        )
    }

    private func restoreLayout(profileKey: String,
                               profileLabel: String,
                               successLogMessage: (LayoutSnapshot) -> String) -> RestoreResult {
        // A new restore decides afresh which windows still need protecting.
        restoreGuard = nil
        guard let snapshot = snapshotStore.load(profileKey: profileKey) else {
            snapshotStore.cancelRestore()
            return .missing(profileLabel: profileLabel)
        }

        let configuration = configManager.configuration
        let profileName = configuration.profileName(for: screenSession.screenCount)
        // Rules with a connected target restore their saved geometry through
        // RuleApplyService. Other apps use the ordinary snapshot restore path.
        let ruleApps = configuration.effectiveRules.filter { rule in
            screenSession.screenDetector.screenInfo(
                forAlias: rule.resolvedTargetScreen(for: profileName),
                configuration: configuration
            ) != nil
        }.map(\.app)
        snapshotStore.restoreSnapshot(
            snapshot,
            windowManager: windowManager,
            excludeAppMatchers: ruleApps,
            windowFilter: WindowFilter(configuration: configuration),
            completion: { [weak self] outcome in
                self?.installRestoreGuard(from: outcome)
            }
        )
        let message = successLogMessage(snapshot)
        Log.snapshot.info(message)
        return .restored(profileLabel: snapshot.profileLabel)
    }

}

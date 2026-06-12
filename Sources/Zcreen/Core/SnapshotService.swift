import Foundation

final class SnapshotService {
    enum Trigger: String {
        case manual
        case periodic
        case snapBar = "snap_bar"
        case screenChange = "screen_change"
        case screenWillChange = "screen_will_change"
        case appLaunch = "app_launch"

        var logLabel: String { rawValue }
    }

    enum SaveResult {
        case saved(windowCount: Int)
        case noWindows
        case unchanged

        var statusMessage: String? {
            switch self {
            case let .saved(windowCount):
                return "Saved layout (\(windowCount) windows)"
            case .noWindows:
                return "No windows available to save"
            case .unchanged:
                return nil
            }
        }
    }

    enum RestoreResult {
        case restored(profileLabel: String)
        case missing(profileLabel: String)

        var statusMessage: String {
            switch self {
            case let .restored(profileLabel):
                return "Restored layout for \(profileLabel)"
            case let .missing(profileLabel):
                return "No saved layout for \(profileLabel)"
            }
        }
    }

    private let screenSession: ScreenSessionService
    private let configManager: ConfigManager
    private let windowManager: WindowManager
    private let snapshotStore: LayoutSnapshotStore

    init(screenSession: ScreenSessionService,
         configManager: ConfigManager,
         windowManager: WindowManager,
         snapshotStore: LayoutSnapshotStore) {
        self.screenSession = screenSession
        self.configManager = configManager
        self.windowManager = windowManager
        self.snapshotStore = snapshotStore
    }

    func saveCurrentLayout(trigger: Trigger, force: Bool) -> SaveResult {
        let captured = snapshotStore.captureSnapshot(
            profileKey: screenSession.currentProfileKey,
            profileLabel: screenSession.currentProfileLabel,
            windowManager: windowManager,
            screens: screenSession.currentScreens,
            windowFilter: currentWindowFilter()
        )

        guard !captured.windows.isEmpty else {
            Log.snapshot.info("Skipped snapshot save [\(trigger.logLabel)] because no windows were captured")
            return .noWindows
        }

        let existing = snapshotStore.load(profileKey: captured.profileKey)
        let snapshot = merging(captured: captured, into: existing)

        if !force,
           let existing,
           existing.windows == snapshot.windows {
            Log.snapshot.info("Skipped snapshot save [\(trigger.logLabel)] because layout is unchanged")
            return .unchanged
        }

        snapshotStore.save(snapshot: snapshot)
        Log.snapshot.info("Saved snapshot [\(trigger.logLabel)] for '\(snapshot.profileLabel)'")
        return .saved(windowCount: snapshot.windows.count)
    }

    /// AX occasionally returns zero windows for individual apps (busy, mid-launch,
    /// lock-screen edge). Overwriting the stored snapshot with such a capture would
    /// permanently lose those apps' saved positions, so entries for apps that exist
    /// in the stored snapshot but are entirely absent from this capture are carried
    /// over. Apps present in the capture are always taken as-is.
    private func merging(captured: LayoutSnapshot, into existing: LayoutSnapshot?) -> LayoutSnapshot {
        guard let existing else { return captured }

        let capturedBundleIds = Set(captured.windows.map(\.bundleId))
        let preserved = existing.windows.filter { !capturedBundleIds.contains($0.bundleId) }
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
                "Restored \(snapshot.windows.count) windows for '\(snapshot.profileLabel)'"
            }
        )
    }

    private func restoreLayout(profileKey: String,
                               profileLabel: String,
                               successLogMessage: (LayoutSnapshot) -> String) -> RestoreResult {
        guard let snapshot = snapshotStore.load(profileKey: profileKey) else {
            return .missing(profileLabel: profileLabel)
        }

        snapshotStore.restoreSnapshot(
            snapshot,
            windowManager: windowManager,
            excludeBundleIds: [],
            windowFilter: currentWindowFilter()
        )
        let message = successLogMessage(snapshot)
        Log.snapshot.info(message)
        return .restored(profileLabel: snapshot.profileLabel)
    }

    private func currentWindowFilter() -> WindowFilter {
        WindowFilter(configuration: configManager.configuration)
    }
}

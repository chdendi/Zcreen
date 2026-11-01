import AppKit
import CoreGraphics
import Foundation

final class RuleApplyService {
    struct RunningApp {
        let bundleId: String?
        let name: String?

        static func current() -> [RunningApp] {
            NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .map { RunningApp(bundleId: $0.bundleIdentifier, name: $0.localizedName) }
        }
    }

    enum ApplyResult {
        case noRulesConfigured
        case applied(moveCount: Int)

        var statusMessage: String {
            switch self {
            case .noRulesConfigured:
                return "No rules configured"
            case let .applied(moveCount):
                return "Applied \(moveCount) rule moves"
            }
        }
    }

    struct AppLaunchResult {
        let appName: String
        let targetScreenAlias: String

        var statusMessage: String {
            "Moved \(appName) to \(targetScreenAlias)"
        }
    }

    private let screenSession: ScreenSessionService
    private let configManager: ConfigManager
    private let windowManager: WindowManager
    private let ruleEngine: RuleEngine
    private let snapshotStore: LayoutSnapshotStore
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void
    private let runningApps: () -> [RunningApp]
    /// Shared cancellation token for launch polling and post-restore rule retries.
    private var workGeneration: UInt64 = 0
    /// Scheduled closures of the current generation that have not run yet.
    private var pendingWorkCount = 0

    /// Stops launch polling and rule retries. Returns whether any were still scheduled.
    @discardableResult
    func cancelPendingWork() -> Bool {
        let hadPendingWork = pendingWorkCount > 0
        workGeneration &+= 1
        pendingWorkCount = 0
        return hadPendingWork
    }

    init(screenSession: ScreenSessionService,
         configManager: ConfigManager,
         windowManager: WindowManager,
         ruleEngine: RuleEngine,
         snapshotStore: LayoutSnapshotStore,
         scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void,
         runningApps: @escaping () -> [RunningApp] = RunningApp.current) {
        self.screenSession = screenSession
        self.configManager = configManager
        self.windowManager = windowManager
        self.ruleEngine = ruleEngine
        self.snapshotStore = snapshotStore
        self.scheduleAfter = scheduleAfter
        self.runningApps = runningApps
    }

    private func schedule(after delay: TimeInterval, generation: UInt64, _ work: @escaping () -> Void) {
        pendingWorkCount += 1
        scheduleAfter(delay) { [weak self] in
            guard let self else { return }
            if generation == self.workGeneration { self.pendingWorkCount -= 1 }
            work()
        }
    }

    func applyAllRules() -> ApplyResult {
        let config = configManager.configuration
        guard !config.effectiveRules.isEmpty else {
            return .noRulesConfigured
        }

        let matches = ruleEngine.matchRules(configuration: config, screenCount: screenSession.screenCount)
        return .applied(moveCount: applyResolvedRules(matches, configuration: config))
    }

    /// Applies rules after a restore. Rule apps are left out of the snapshot restore, so they
    /// get the same retry treatment: a running app whose windows AX cannot see yet (common
    /// right after a display change or wake) is retried with backoff.
    @discardableResult
    func applyRulesIfAvailable() -> Int? {
        let config = configManager.configuration
        guard !config.effectiveRules.isEmpty else {
            return nil
        }

        let matches = ruleEngine.matchRules(configuration: config, screenCount: screenSession.screenCount)
        return applyResolvedRules(matches, configuration: config, retryAttempt: 0, generation: workGeneration)
    }

    @discardableResult
    func applyFallbackRulesIfAvailable() -> Int? {
        applyRulesIfAvailable()
    }

    func handleAppLaunch(bundleId: String?, appName: String?, completion: @escaping (AppLaunchResult?) -> Void) {
        let config = configManager.configuration
        guard !config.effectiveRules.isEmpty else {
            completion(nil)
            return
        }

        guard let match = ruleEngine.matchRule(
            for: bundleId,
            appName: appName,
            configuration: config,
            screenCount: screenSession.screenCount
        ) else {
            completion(nil)
            return
        }

        guard screenSession.screenDetector.screenInfo(
            forAlias: match.targetScreenAlias,
            configuration: config
        ) != nil, let matchedBundleId = match.matchedBundleId else {
            completion(nil)
            return
        }

        let generation = workGeneration
        waitForWindows(
            bundleId: matchedBundleId,
            generation: generation,
            action: { [weak self] windows in
                guard let self else { return }
                guard generation == self.workGeneration else { completion(nil); return }
                let currentConfig = self.configManager.configuration
                guard let currentMatch = self.ruleEngine.matchRule(for: matchedBundleId, appName: appName,
                    configuration: currentConfig, screenCount: self.screenSession.screenCount),
                      let currentTarget = self.screenSession.screenDetector.screenInfo(
                        forAlias: currentMatch.targetScreenAlias, configuration: currentConfig) else {
                    completion(nil)
                    return
                }

                _ = self.applyWindows(windows.filter(WindowFilter(configuration: currentConfig).allows(window:)),
                                      to: currentTarget, configuration: currentConfig)

                Log.rule.info("Launch rule: \(appName ?? "unknown") -> \(currentMatch.targetScreenAlias)")
                completion(AppLaunchResult(appName: appName ?? "app", targetScreenAlias: currentMatch.targetScreenAlias))
            },
            onTimeout: {
                completion(nil)
            }
        )
    }

    private func waitForWindows(bundleId: String,
                                generation: UInt64,
                                attempt: Int = 1,
                                action: @escaping ([WindowManager.WindowInfo]) -> Void,
                                onTimeout: (() -> Void)? = nil) {
        guard generation == workGeneration else { onTimeout?(); return }
        let windows = windowManager.getWindows(bundleId: bundleId,
            filter: WindowFilter(configuration: configManager.configuration))
        if !windows.isEmpty {
            action(windows)
        } else if attempt < Constants.Timing.appLaunchPollMaxAttempts {
            schedule(after: Constants.Timing.appLaunchPollInterval, generation: generation) { [weak self] in
                self?.waitForWindows(
                    bundleId: bundleId,
                    generation: generation,
                    attempt: attempt + 1,
                    action: action,
                    onTimeout: onTimeout
                )
            }
        } else {
            Log.rule.info(
                "Launch rule: gave up waiting for windows of \(bundleId) after \(Constants.Timing.appLaunchPollMaxAttempts) attempts"
            )
            onTimeout?()
        }
    }

    /// - Parameter retryAttempt: nil disables retries (manual "apply rules").
    private func applyResolvedRules(_ matches: [RuleEngine.RuleMatch], configuration: Configuration,
                                    retryAttempt: Int? = nil, generation: UInt64? = nil) -> Int {
        let windows = windowManager.getAllWindows(filter: WindowFilter(configuration: configuration))
        // Match all windows of an app together so each saved window is used once.
        let windowsByBundle = Dictionary(grouping: windows, by: { $0.bundleId ?? "pid:\($0.pid)" })
        var applied = 0
        var servedRules = Set<Int>()

        for appWindows in windowsByBundle.values {
            guard let win = appWindows.first else { continue }
            guard let matchIndex = matches.firstIndex(where: {
                $0.rule.app.matches(bundleId: win.bundleId, appName: win.appName)
            }) else {
                continue
            }
            servedRules.insert(matchIndex)

            guard let targetScreen = screenSession.screenDetector.screenInfo(
                forAlias: matches[matchIndex].targetScreenAlias,
                configuration: configuration
            ) else {
                continue
            }

            applied += applyWindows(appWindows, to: targetScreen, configuration: configuration)
        }

        if let retryAttempt, let generation {
            scheduleRuleRetry(for: matches.enumerated().filter { !servedRules.contains($0.offset) }.map(\.element),
                              configuration: configuration, attempt: retryAttempt, generation: generation)
        }
        return applied
    }

    private func scheduleRuleRetry(for unserved: [RuleEngine.RuleMatch], configuration: Configuration,
                                   attempt: Int, generation: UInt64) {
        guard generation == workGeneration, attempt < Constants.Timing.snapshotMaxRetries else { return }
        let running = runningApps()
        let waiting = unserved.filter { match in
            screenSession.screenDetector.screenInfo(forAlias: match.targetScreenAlias, configuration: configuration) != nil
                && running.contains { match.rule.app.matches(bundleId: $0.bundleId, appName: $0.name) }
        }
        guard !waiting.isEmpty else { return }

        Log.rule.info("Rule apps still without windows: \(waiting.count); retry \(attempt + 1)")
        let delay = Constants.Timing.snapshotRetryBaseDelay * pow(2, Double(attempt))
        schedule(after: delay, generation: generation) { [weak self] in
            guard let self, generation == self.workGeneration else { return }
            let applied = self.applyResolvedRules(waiting, configuration: self.configManager.configuration,
                                                  retryAttempt: attempt + 1, generation: generation)
            if applied > 0 {
                Log.rule.info("Applied \(applied) rule moves on retry \(attempt + 1)")
            }
        }
    }

    private func applyWindows(_ windows: [WindowManager.WindowInfo], to targetScreen: ScreenInfo,
                              configuration: Configuration) -> Int {
        let screens = screenSession.currentScreens
        let windowFilter = WindowFilter(configuration: configuration)
        let savedWindows = snapshotStore.load(profileKey: screenSession.currentProfileKey)?.windows.filter {
            $0.bundleId == windows.first?.bundleId && windowFilter.allows(snapshot: $0)
                && $0.resolvedFrame(on: targetScreen, using: screens) != nil
        } ?? []
        let candidates = windows.map { win -> WindowMatchCandidate in
            let screen = CoordinateConverter.screenContainingAccessibilityPoint(
                CGPoint(x: win.frame.midX, y: win.frame.midY), in: screens
            )
            return WindowMatchCandidate(title: win.title, frame: win.frame,
                                        screenName: screen?.name ?? "Unknown", screenKey: screen?.uniqueKey,
                                        role: win.role, subrole: win.subrole)
        }
        let assignments = WindowMatcher.match(
            saved: savedWindows, running: candidates,
            savedElements: snapshotStore.identityElements(for: savedWindows, profileKey: screenSession.currentProfileKey),
            runningElements: windows.map(\.axWindow)
        )
        let savedByRunningIndex = Dictionary(uniqueKeysWithValues: assignments.map {
            ($0.runningIndex, savedWindows[$0.savedIndex])
        })

        var applied = 0
        for (index, win) in windows.enumerated() {
            if let saved = savedByRunningIndex[index],
               let target = saved.resolvedFrame(on: targetScreen, using: screens) {
                if win.frame.isClose(to: target, tolerance: Constants.Restore.inPlaceTolerance) { continue }
                windowManager.moveWindow(win.axWindow, toFrame: target)
                Log.rule.info("Restored saved geometry for \(win.appName) on \(targetScreen.name) at \(target.debugDescription)")
                applied += 1
                continue
            }

            let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
            if CoordinateConverter.containsAccessibilityPoint(
                center,
                in: targetScreen,
                screens: screens
            ) {
                continue
            }

            windowManager.moveWindowToScreen(win.axWindow, currentFrame: win.frame, targetScreen: targetScreen)
            applied += 1
        }

        return applied
    }
}

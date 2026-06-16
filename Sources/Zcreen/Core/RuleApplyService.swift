import CoreGraphics
import Foundation

final class RuleApplyService {
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
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void

    init(screenSession: ScreenSessionService,
         configManager: ConfigManager,
         windowManager: WindowManager,
         ruleEngine: RuleEngine,
         scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void) {
        self.screenSession = screenSession
        self.configManager = configManager
        self.windowManager = windowManager
        self.ruleEngine = ruleEngine
        self.scheduleAfter = scheduleAfter
    }

    func applyAllRules() -> ApplyResult {
        let config = configManager.configuration
        guard !config.effectiveRules.isEmpty else {
            return .noRulesConfigured
        }

        let matches = ruleEngine.matchRules(configuration: config, screenCount: screenSession.screenCount)
        return .applied(moveCount: applyResolvedRules(matches, configuration: config))
    }

    @discardableResult
    func applyRulesIfAvailable() -> Int? {
        let config = configManager.configuration
        guard !config.effectiveRules.isEmpty else {
            return nil
        }

        let matches = ruleEngine.matchRules(configuration: config, screenCount: screenSession.screenCount)
        return applyResolvedRules(matches, configuration: config)
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

        guard let targetScreen = screenSession.screenDetector.screenInfo(
            forAlias: match.targetScreenAlias,
            configuration: config
        ), let matchedBundleId = match.matchedBundleId else {
            completion(nil)
            return
        }

        let windowFilter = WindowFilter(configuration: config)
        waitForWindows(
            bundleId: matchedBundleId,
            windowFilter: windowFilter,
            action: { [weak self] windows in
                guard let self else { return }

                for win in windows {
                    let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
                    if CoordinateConverter.containsAccessibilityPoint(
                        center,
                        in: targetScreen,
                        screens: self.screenSession.currentScreens
                    ) {
                        continue
                    }
                    self.windowManager.moveWindowToScreen(
                        win.axWindow,
                        currentFrame: win.frame,
                        targetScreen: targetScreen
                    )
                }

                Log.rule.info("Launch rule: \(appName ?? "unknown") -> \(match.targetScreenAlias)")
                completion(AppLaunchResult(appName: appName ?? "app", targetScreenAlias: match.targetScreenAlias))
            },
            onTimeout: {
                completion(nil)
            }
        )
    }

    private func waitForWindows(bundleId: String,
                                windowFilter: WindowFilter,
                                attempt: Int = 1,
                                action: @escaping ([WindowManager.WindowInfo]) -> Void,
                                onTimeout: (() -> Void)? = nil) {
        let windows = windowManager.getWindows(bundleId: bundleId, filter: windowFilter)
        if !windows.isEmpty {
            action(windows)
        } else if attempt < Constants.Timing.appLaunchPollMaxAttempts {
            scheduleAfter(Constants.Timing.appLaunchPollInterval) { [weak self] in
                self?.waitForWindows(
                    bundleId: bundleId,
                    windowFilter: windowFilter,
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

    private func applyResolvedRules(_ matches: [RuleEngine.RuleMatch], configuration: Configuration) -> Int {
        let windows = windowManager.getAllWindows(filter: WindowFilter(configuration: configuration))
        var applied = 0

        for win in windows {
            guard let match = matches.first(where: {
                $0.rule.app.matches(bundleId: win.bundleId, appName: win.appName)
            }) else {
                continue
            }

            guard let targetScreen = screenSession.screenDetector.screenInfo(
                forAlias: match.targetScreenAlias,
                configuration: configuration
            ) else {
                continue
            }

            let center = CGPoint(x: win.frame.midX, y: win.frame.midY)
            if CoordinateConverter.containsAccessibilityPoint(
                center,
                in: targetScreen,
                screens: screenSession.currentScreens
            ) {
                continue
            }

            windowManager.moveWindowToScreen(win.axWindow, currentFrame: win.frame, targetScreen: targetScreen)
            applied += 1
        }

        return applied
    }
}

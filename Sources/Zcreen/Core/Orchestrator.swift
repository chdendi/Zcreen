import Cocoa
import Combine

final class Orchestrator: ObservableObject {
    @Published private(set) var lastAction: String = ""

    let screenDetector: ScreenDetector
    let configManager: ConfigManager
    let windowManager: WindowManager
    let snapshotStore: LayoutSnapshotStore
    let ruleEngine: RuleEngine
    let snapBarController: SnapBarController
    let caffeinateManager: CaffeinateManager
    let autoUpdater: AutoUpdater
    let menuState: MenuState

    private let screenSessionService: ScreenSessionService
    private let snapshotService: SnapshotService
    private let ruleApplyService: RuleApplyService
    private let powerMonitor: PowerStateMonitor
    private let isAccessibilityTrusted: () -> Bool
    private let requestAccessibilityAccess: () -> Void
    private let scheduleAfter: (TimeInterval, @escaping () -> Void) -> Void

    private var cancellables = Set<AnyCancellable>()
    private var autoSaveTimer: Timer?

    // MARK: - Wake-settle state machine
    //
    // After resume the orchestrator runs an adaptive debounce instead of a single
    // fixed-delay restore. Two stages live inside one "wake-settle window":
    //
    //   awaitingFirstRestore — no restore yet. Each reconfig event re-arms the
    //     debounce timer; if a profile matching `wakeSettleExpectedKey`
    //     (= the pre-suspend profile) shows up, restore immediately. Otherwise we
    //     wait at most `wakeSettleDelay` of silence before doing a best-effort
    //     restore against whatever the detector currently reports.
    //
    //   awaitingExit (cooldown) — first restore has fired. Reconfig events that
    //     match the last restored profile are absorbed (re-arm cooldown only).
    //     Events that drift back to expected re-trigger restore. Other transients
    //     are absorbed too — we don't chase every flicker macOS emits while it's
    //     still negotiating modes on external displays.
    //
    // The window exits after `wakeSettleCooldownDelay` of silence post-restore.
    private enum WakeSettleStage {
        case awaitingFirstRestore
        case awaitingExit
    }
    /// Generation token for the wake-settle scheduler closure. Each new event
    /// bumps it; queued closures only run if their captured generation still
    /// matches, which gives us free cancellation of stale timers.
    private var wakeSettleGeneration: UInt64 = 0
    private var isInWakeSettleWindow: Bool = false
    private var wakeSettleStage: WakeSettleStage = .awaitingFirstRestore
    /// Profile key from before the suspend cycle, used as the heuristic target —
    /// matching it short-circuits the debounce wait.
    private var wakeSettleExpectedKey: String = ""
    /// Last profile we restored to inside this wake-settle window. Used in
    /// cooldown to decide whether a new event is just a duplicate echo or a
    /// genuine drift that warrants another restore.
    private var wakeSettleLastRestoredKey: String = ""

    var autoApplyOnScreenChange: Bool {
        get { menuState.autoApplyOnScreenChange }
        set { menuState.autoApplyOnScreenChange = newValue }
    }

    var autoApplyOnAppLaunch: Bool {
        get { menuState.autoApplyOnAppLaunch }
        set { menuState.autoApplyOnAppLaunch = newValue }
    }

    init(
        screenDetector: ScreenDetector = ScreenDetector(),
        configManager: ConfigManager = ConfigManager(),
        windowManager: WindowManager = WindowManager(),
        snapshotStore: LayoutSnapshotStore = LayoutSnapshotStore(),
        ruleEngine: RuleEngine = RuleEngine(),
        snapBarController: SnapBarController? = nil,
        caffeinateManager: CaffeinateManager = CaffeinateManager(),
        autoUpdater: AutoUpdater = AutoUpdater(),
        settingsStore: MenuSettingsStore = MenuSettingsStore(),
        isAccessibilityTrusted: @escaping () -> Bool = { AccessibilityHelper.isTrusted },
        requestAccessibilityAccess: @escaping () -> Void = { AccessibilityHelper.requestAccess() },
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        },
        powerMonitor: PowerStateMonitor = PowerStateMonitor(),
        enableAppLaunchObserver: Bool = true,
        enableAutoSaveTimer: Bool = true
    ) {
        self.screenDetector = screenDetector
        self.configManager = configManager
        self.windowManager = windowManager
        self.snapshotStore = snapshotStore
        self.ruleEngine = ruleEngine

        // Inject the live ScreenDetector so the snapshot store stops maintaining a parallel
        // NSScreen-derived view of displays.
        snapshotStore.setScreenDetector(screenDetector)

        let resolvedSnapBarController = snapBarController ?? SnapBarController(windowManager: windowManager)
        self.snapBarController = resolvedSnapBarController
        self.caffeinateManager = caffeinateManager
        self.autoUpdater = autoUpdater

        let resolvedMenuState = MenuState(settingsStore: settingsStore)
        resolvedMenuState.connect(snapBarController: resolvedSnapBarController)
        self.menuState = resolvedMenuState

        let resolvedScreenSessionService = ScreenSessionService(screenDetector: screenDetector)
        self.screenSessionService = resolvedScreenSessionService
        self.snapshotService = SnapshotService(
            screenSession: resolvedScreenSessionService,
            configManager: configManager,
            windowManager: windowManager,
            snapshotStore: snapshotStore
        )
        self.ruleApplyService = RuleApplyService(
            screenSession: resolvedScreenSessionService,
            configManager: configManager,
            windowManager: windowManager,
            ruleEngine: ruleEngine,
            scheduleAfter: scheduleAfter
        )

        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.requestAccessibilityAccess = requestAccessibilityAccess
        self.scheduleAfter = scheduleAfter
        self.powerMonitor = powerMonitor

        resolvedSnapBarController.onSnap = { [weak self] in
            self?.autoSaveCurrentLayout(trigger: .snapBar)
        }

        forwardChanges(
            snapshotStore.objectWillChange.eraseToAnyPublisher(),
            screenDetector.objectWillChange.eraseToAnyPublisher(),
            autoUpdater.objectWillChange.eraseToAnyPublisher(),
            configManager.objectWillChange.eraseToAnyPublisher(),
            resolvedSnapBarController.objectWillChange.eraseToAnyPublisher(),
            resolvedMenuState.objectWillChange.eraseToAnyPublisher()
        )

        setupScreenChangeHandler()
        if enableAppLaunchObserver {
            setupAppLaunchHandler()
        }
        if enableAutoSaveTimer {
            setupAutoSaveTimer()
        }
    }

    deinit {
        autoSaveTimer?.invalidate()
    }

    // MARK: - Public actions

    func applyAllRules() {
        guard ensureAccessibilityPermission(promptIfNeeded: true) else { return }

        let result = ruleApplyService.applyAllRules()
        lastAction = result.statusMessage
        Log.rule.info(self.lastAction)
    }

    func saveCurrentLayout() {
        guard ensureAccessibilityPermission(promptIfNeeded: true) else { return }

        let result = snapshotService.saveCurrentLayout(trigger: .manual, force: true)
        if let statusMessage = result.statusMessage {
            lastAction = statusMessage
        }
    }

    func restoreCurrentLayout() {
        guard ensureAccessibilityPermission(promptIfNeeded: true) else { return }

        lastAction = snapshotService.restoreCurrentLayout().statusMessage
    }

    // MARK: - Post-change restore

    private func setupScreenChangeHandler() {
        screenDetector.onScreensChanged
            .sink { [weak self] newProfileKey in
                guard let self, self.menuState.autoApplyOnScreenChange else { return }
                self.routeScreenChange(newProfileKey: newProfileKey)
            }
            .store(in: &cancellables)

        // The begin pulse arrives before macOS starts rearranging windows, so this
        // save captures the last user-arranged layout under the still-current
        // profile — closing the up-to-15s gap since the previous periodic save.
        screenDetector.onBeginConfiguration
            .sink { [weak self] in
                self?.handleScreenWillChange()
            }
            .store(in: &cancellables)

        // After resume, enter an adaptive wake-settle window that uses the
        // pre-suspend profile as its heuristic target.
        powerMonitor.onResumed
            .sink { [weak self] in
                guard let self, self.menuState.autoApplyOnScreenChange else { return }
                self.enterWakeSettleWindow()
            }
            .store(in: &cancellables)
    }

    /// Top-level gate for screen reconfig events.
    ///
    /// - Suspended → drop entirely; restore happens once after resume.
    /// - In wake-settle window → hand off to the state machine below.
    /// - Otherwise → run inline (historical behavior).
    func routeScreenChange(newProfileKey: String) {
        if powerMonitor.isSuspended {
            Log.screen.info("Screen change ignored: system suspended (profile=\(newProfileKey))")
            return
        }
        if isInWakeSettleWindow {
            handleScreenChangeInWakeSettle(newProfileKey: newProfileKey)
            return
        }
        handleScreenChange(newProfileKey: newProfileKey)
    }

    func enterWakeSettleWindow() {
        let expected = screenSessionService.previousProfileKey
        Log.screen.info("Power: resumed — entering wake-settle window (expected=\(expected))")
        isInWakeSettleWindow = true
        wakeSettleStage = .awaitingFirstRestore
        wakeSettleExpectedKey = expected
        wakeSettleLastRestoredKey = ""
        armWakeSettleTimer()
    }

    private func handleScreenChangeInWakeSettle(newProfileKey: String) {
        switch wakeSettleStage {
        case .awaitingFirstRestore:
            if !wakeSettleExpectedKey.isEmpty, newProfileKey == wakeSettleExpectedKey {
                Log.screen.info("Wake-settle: matched expected profile, restoring early (profile=\(newProfileKey))")
                restoreInWakeSettle(profileKey: newProfileKey)
            } else {
                Log.screen.info("Wake-settle: awaiting expected (have=\(newProfileKey) want=\(self.wakeSettleExpectedKey)) — re-arm")
                armWakeSettleTimer()
            }

        case .awaitingExit:
            // Drift back to the heuristic target → re-restore. The expected key
            // can't be empty here (otherwise we never set lastRestoredKey to it),
            // but the comparison still has to gate on lastRestored to avoid a
            // pointless second restore to the same target.
            if !wakeSettleExpectedKey.isEmpty,
               newProfileKey == wakeSettleExpectedKey,
               wakeSettleLastRestoredKey != wakeSettleExpectedKey {
                Log.screen.info("Wake-settle cooldown: profile drifted back to expected — re-restoring")
                restoreInWakeSettle(profileKey: newProfileKey)
            } else {
                // Either an echo of the last restored profile or a transient
                // flicker; absorb it and re-arm the cooldown.
                Log.screen.info("Wake-settle cooldown: absorbing event (profile=\(newProfileKey) lastRestored=\(self.wakeSettleLastRestoredKey))")
                armWakeSettleTimer()
            }
        }
    }

    private func restoreInWakeSettle(profileKey: String) {
        handleScreenChange(newProfileKey: profileKey)
        wakeSettleLastRestoredKey = profileKey
        wakeSettleStage = .awaitingExit
        armWakeSettleTimer()
    }

    private func armWakeSettleTimer() {
        wakeSettleGeneration &+= 1
        let myGeneration = wakeSettleGeneration
        let stage = wakeSettleStage
        let delay: TimeInterval = stage == .awaitingFirstRestore
            ? Constants.Timing.wakeSettleDelay
            : Constants.Timing.wakeSettleCooldownDelay

        scheduleAfter(delay) { [weak self] in
            guard let self else { return }
            // Stale generation? A newer event re-armed; this closure is dead.
            guard self.wakeSettleGeneration == myGeneration else { return }

            switch stage {
            case .awaitingFirstRestore:
                // Heuristic never matched within the timeout — best-effort restore
                // against whatever the detector currently reports.
                let key = self.screenDetector.profileKey
                Log.screen.info("Wake-settle timeout: restoring against current profile=\(key)")
                self.restoreInWakeSettle(profileKey: key)
            case .awaitingExit:
                // Cooldown may have absorbed a genuine change (e.g. a display plugged
                // in mid-cooldown). If the detector's profile no longer matches what
                // we last restored, restore once more instead of exiting stale.
                let current = self.screenDetector.profileKey
                if !current.isEmpty, current != self.wakeSettleLastRestoredKey {
                    Log.screen.info("Wake-settle cooldown elapsed with drifted profile (\(current)) — restoring before exit")
                    self.restoreInWakeSettle(profileKey: current)
                } else {
                    Log.screen.info("Wake-settle cooldown elapsed — exiting wake-settle window")
                    self.isInWakeSettleWindow = false
                }
            }
        }
    }

    /// Best-effort save of the current (pre-change) profile the moment a display
    /// reconfiguration is announced, while windows are still where the user left them.
    func handleScreenWillChange() {
        autoSaveCurrentLayout(trigger: .screenWillChange)
    }

    func handleScreenChange(newProfileKey: String) {
        guard ensureAccessibilityPermission(promptIfNeeded: false) else { return }

        let context = screenSessionService.recordScreenChange(to: newProfileKey)
        Log.general.info("Screen change: '\(context.oldProfileKey)' -> '\(context.newProfileKey)' (\(context.newProfileLabel))")

        let restoreResult = snapshotService.restoreLayout(
            profileKey: context.newProfileKey,
            profileLabel: context.newProfileLabel
        )
        switch restoreResult {
        case .restored:
            lastAction = restoreResult.statusMessage
        case .missing:
            _ = ruleApplyService.applyFallbackRulesIfAvailable()
            lastAction = "New screen combo: \(context.newProfileLabel)"
            Log.snapshot.info("No snapshot for '\(context.newProfileLabel)', used rules as fallback")
        }

        scheduleDelayedAutoSave(trigger: .screenChange, delay: Constants.Timing.screenChangeAutoSaveDelay)
    }

    // MARK: - App launch rules

    private func setupAppLaunchHandler() {
        NSWorkspace.shared.notificationCenter
            .publisher(for: NSWorkspace.didLaunchApplicationNotification)
            .compactMap { $0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication }
            .sink { [weak self] app in
                guard let self, self.menuState.autoApplyOnAppLaunch else { return }
                self.handleAppLaunch(bundleId: app.bundleIdentifier, appName: app.localizedName)
            }
            .store(in: &cancellables)
    }

    func handleAppLaunch(bundleId: String?, appName: String?) {
        guard ensureAccessibilityPermission(promptIfNeeded: false) else { return }

        ruleApplyService.handleAppLaunch(bundleId: bundleId, appName: appName) { [weak self] result in
            guard let self, let result else { return }

            self.lastAction = result.statusMessage
            self.scheduleDelayedAutoSave(trigger: .appLaunch, delay: Constants.Timing.appLaunchAutoSaveDelay)
        }
    }

    private func setupAutoSaveTimer() {
        let timer = Timer(timeInterval: Constants.Timing.layoutAutoSaveInterval, repeats: true) { [weak self] _ in
            self?.autoSaveCurrentLayout(trigger: .periodic)
        }
        RunLoop.main.add(timer, forMode: .common)
        autoSaveTimer = timer
    }

    private func scheduleDelayedAutoSave(trigger: SnapshotService.Trigger, delay: TimeInterval) {
        scheduleAfter(delay) { [weak self] in
            self?.autoSaveCurrentLayout(trigger: trigger)
        }
    }

    func performPeriodicAutoSaveForTesting() {
        autoSaveCurrentLayout(trigger: .periodic)
    }

    private func autoSaveCurrentLayout(trigger: SnapshotService.Trigger) {
        // Never persist layouts while the system is suspended (sleep/lock) or still
        // settling after wake — captures taken in those windows are the transitional
        // states macOS produces mid-reconfig, and saving them overwrites good snapshots.
        if powerMonitor.isSuspended || isInWakeSettleWindow {
            Log.snapshot.info("Skipped snapshot save [\(trigger.logLabel)]: system suspended or settling after wake")
            return
        }
        guard ensureAccessibilityPermission(promptIfNeeded: false) else { return }
        _ = snapshotService.saveCurrentLayout(trigger: trigger, force: false)
    }

    @discardableResult
    private func ensureAccessibilityPermission(promptIfNeeded: Bool) -> Bool {
        guard isAccessibilityTrusted() else {
            if promptIfNeeded {
                lastAction = "Accessibility permission required"
                requestAccessibilityAccess()
            }
            return false
        }

        return true
    }

    /// Merge several `objectWillChange` publishers into a single sink so SwiftUI receives one
    /// "parent changed" event per child mutation without N independent subscriptions.
    /// The publishers are erased to a common type because each ObservableObject's
    /// `ObjectWillChangePublisher` is concretely different.
    private func forwardChanges(_ publishers: AnyPublisher<Void, Never>...) {
        Publishers.MergeMany(publishers)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }
}

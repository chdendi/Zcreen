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
    private let now: () -> Date
    private let secondsSinceLastUserInput: () -> TimeInterval

    private var cancellables = Set<AnyCancellable>()
    private var autoSaveTimer: Timer?
    private var screenSaveGeneration: UInt64 = 0
    private var isScreenReconfiguring = false
    /// Last begin / completion event, used by the watchdog that unsticks `isScreenReconfiguring`.
    private var lastReconfigActivityAt: Date?
    /// When a capture last ran. The periodic save skips its AX sweep if the user has not
    /// touched mouse or keyboard since then.
    private var lastLayoutCaptureAt: Date?
    /// Launch rules that arrived while displays were changing; replayed once they settle.
    private var deferredAppLaunches: [(bundleId: String?, appName: String?)] = []

    // MARK: - Wake-settle state machine
    //
    // After resume the orchestrator runs an adaptive debounce instead of a single
    // fixed-delay restore. Two stages live inside one "wake-settle window":
    //
    //   awaitingFirstRestore — no restore yet. Each reconfig event re-arms the
    //     debounce timer; if a profile matching `wakeSettleExpectedKey`
    //     (= the pre-suspend profile) shows up, restore immediately. Otherwise we
    //     wait at most `wakeSettleDelay` of silence (shorter when a display that was
    //     not connected before suspend appears) before a best-effort restore against
    //     whatever the detector currently reports. If no display event happened at all
    //     and the topology is unchanged, macOS never moved anything: skip the restore.
    //
    //   awaitingExit (cooldown) — first restore has fired. Reconfig events are absorbed
    //     (re-arm cooldown only) unless the profile drifts back to expected. When the
    //     cooldown elapses we restore once more if the profile or the display geometry
    //     changed since the last restore, or if a begin pulse interrupted that restore
    //     before it finished; otherwise the window closes.
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
    /// Last profile / geometry we restored to inside this wake-settle window.
    private var wakeSettleLastRestoredKey: String = ""
    private var wakeSettleLastRestoredFingerprint: String = ""
    /// A begin pulse cancelled the cooldown restore (or its rule retries) before it finished.
    private var wakeSettleRestoreInterrupted = false
    /// Display state captured when the system suspended.
    private var suspendProfileKey: String?
    private var suspendFingerprint: String?
    private var sawDisplayEventSinceSuspend = false

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
        enableAutoSaveTimer: Bool = true,
        now: @escaping () -> Date = Date.init,
        secondsSinceLastUserInput: @escaping () -> TimeInterval = {
            // kCGAnyInputEventType: any HID or posted input event. Needs no extra permission.
            // If the type cannot be formed, report fresh input so the periodic save still runs.
            CGEventType(rawValue: UInt32.max).map {
                CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
            } ?? 0
        }
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
            snapshotStore: snapshotStore,
            now: now
        )
        self.ruleApplyService = RuleApplyService(
            screenSession: resolvedScreenSessionService,
            configManager: configManager,
            windowManager: windowManager,
            ruleEngine: ruleEngine,
            snapshotStore: snapshotStore,
            scheduleAfter: scheduleAfter
        )

        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.requestAccessibilityAccess = requestAccessibilityAccess
        self.scheduleAfter = scheduleAfter
        self.powerMonitor = powerMonitor
        self.now = now
        self.secondsSinceLastUserInput = secondsSinceLastUserInput

        resolvedSnapBarController.onSnap = { [weak self] in
            self?.autoSaveCurrentLayout(trigger: .snapBar)
        }

        forwardChanges(
            snapshotStore.objectWillChange.eraseToAnyPublisher(),
            screenDetector.objectWillChange.eraseToAnyPublisher(),
            autoUpdater.objectWillChange.eraseToAnyPublisher(),
            configManager.objectWillChange.eraseToAnyPublisher(),
            resolvedSnapBarController.objectWillChange.eraseToAnyPublisher(),
            caffeinateManager.objectWillChange.eraseToAnyPublisher(),
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
        guard !powerMonitor.isSuspended, !isInWakeSettleWindow, !isScreenReconfiguring else {
            lastAction = "Displays are changing. Wait for them to settle, then save again."
            return
        }

        if let statusMessage = captureLayout(trigger: .manual, force: true)?.statusMessage {
            lastAction = statusMessage
        }
    }

    func restoreCurrentLayout() {
        guard ensureAccessibilityPermission(promptIfNeeded: true) else { return }

        lastAction = snapshotService.restoreCurrentLayout().statusMessage
        _ = ruleApplyService.applyRulesIfAvailable()
    }

    // MARK: - Post-change restore

    private func setupScreenChangeHandler() {
        screenDetector.onScreensChanged
            .sink { [weak self] newProfileKey in
                guard let self else { return }
                if self.menuState.autoApplyOnScreenChange {
                    self.routeScreenChange(newProfileKey: newProfileKey)
                } else {
                    self.snapshotStore.cancelRestore()
                    self.ruleApplyService.cancelPendingWork()
                    self.markScreenReconfiguring()
                    self.screenSaveGeneration &+= 1
                    _ = self.screenSessionService.recordScreenChange(to: newProfileKey)
                    self.scheduleDelayedAutoSave(trigger: .screenChange, delay: Constants.Timing.screenChangeAutoSaveDelay)
                }
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
                guard let self else { return }
                if self.menuState.autoApplyOnScreenChange {
                    self.enterWakeSettleWindow()
                } else {
                    self.markScreenReconfiguring()
                    self.screenSaveGeneration &+= 1
                    let key = self.screenDetector.refreshScreens()
                    _ = self.screenSessionService.recordScreenChange(to: key)
                    self.scheduleDelayedAutoSave(trigger: .screenChange, delay: Constants.Timing.screenChangeAutoSaveDelay)
                }
            }
            .store(in: &cancellables)

        powerMonitor.onSuspendedChanged
            .filter { $0 }
            .sink { [weak self] _ in
                self?.handleSuspend()
            }
            .store(in: &cancellables)
    }

    private func handleSuspend() {
        // Windows are still where the user left them. Persist them now: periodic saves
        // stop while suspended, and the last one may be up to 15 seconds old.
        if !isScreenReconfiguring, !isInWakeSettleWindow {
            _ = captureLayout(trigger: .suspend, force: false)
        }
        suspendProfileKey = screenDetector.profileKey
        suspendFingerprint = screenDetector.topologyFingerprint
        sawDisplayEventSinceSuspend = false

        snapshotStore.cancelRestore()
        ruleApplyService.cancelPendingWork()
        wakeSettleGeneration &+= 1
        screenSaveGeneration &+= 1
        isInWakeSettleWindow = false
        isScreenReconfiguring = false
    }

    /// Top-level gate for screen reconfig events.
    ///
    /// - Suspended → drop entirely; restore happens once after resume.
    /// - In wake-settle window → hand off to the state machine below.
    /// - Otherwise → run inline (historical behavior).
    func routeScreenChange(newProfileKey: String) {
        noteDisplayEventIfSettling()
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
        wakeSettleLastRestoredFingerprint = ""
        wakeSettleRestoreInterrupted = false
        armWakeSettleTimer(delay: Constants.Timing.wakeSettleDelay)
    }

    private func handleScreenChangeInWakeSettle(newProfileKey: String) {
        switch wakeSettleStage {
        case .awaitingFirstRestore:
            if !wakeSettleExpectedKey.isEmpty, newProfileKey == wakeSettleExpectedKey {
                Log.screen.info("Wake-settle: matched expected profile, restoring early (profile=\(newProfileKey))")
                restoreInWakeSettle(profileKey: newProfileKey)
            } else if hasDisplayMissingFromExpected(newProfileKey) {
                // A display that was not there before suspend: a different desk, so the
                // expected profile is not coming back. No point waiting the full timeout.
                Log.screen.info("Wake-settle: new display set (have=\(newProfileKey) want=\(self.wakeSettleExpectedKey)) — short wait")
                armWakeSettleTimer(delay: Constants.Timing.wakeSettleForeignDisplayDelay)
            } else {
                Log.screen.info("Wake-settle: awaiting expected (have=\(newProfileKey) want=\(self.wakeSettleExpectedKey)) — re-arm")
                armWakeSettleTimer(delay: Constants.Timing.wakeSettleDelay)
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
                // An echo or a transient flicker; absorb it. The cooldown exit check below
                // catches geometry changes and interrupted restores once events stop.
                Log.screen.info("Wake-settle cooldown: absorbing event (profile=\(newProfileKey) lastRestored=\(self.wakeSettleLastRestoredKey))")
                armWakeSettleTimer(delay: Constants.Timing.wakeSettleCooldownDelay)
            }
        }
    }

    private func hasDisplayMissingFromExpected(_ profileKey: String) -> Bool {
        guard !wakeSettleExpectedKey.isEmpty else { return false }
        let expected = Set(wakeSettleExpectedKey.split(separator: "+"))
        return profileKey.split(separator: "+").contains { !expected.contains($0) }
    }

    private func restoreInWakeSettle(profileKey: String) {
        handleScreenChange(newProfileKey: profileKey)
        wakeSettleLastRestoredKey = profileKey
        wakeSettleLastRestoredFingerprint = screenDetector.topologyFingerprint
        wakeSettleRestoreInterrupted = false
        wakeSettleStage = .awaitingExit
        armWakeSettleTimer(delay: Constants.Timing.wakeSettleCooldownDelay)
    }

    private func armWakeSettleTimer(delay: TimeInterval) {
        wakeSettleGeneration &+= 1
        let myGeneration = wakeSettleGeneration
        let stage = wakeSettleStage

        scheduleAfter(delay) { [weak self] in
            guard let self else { return }
            // Stale generation? A newer event re-armed; this closure is dead.
            guard self.wakeSettleGeneration == myGeneration else { return }

            switch stage {
            case .awaitingFirstRestore:
                let key = self.screenDetector.profileKey
                if !self.sawDisplayEventSinceSuspend,
                   key == self.suspendProfileKey,
                   self.screenDetector.topologyFingerprint == self.suspendFingerprint {
                    // Lock / unlock without any display change: windows never moved, and a
                    // restore would only undo what the user did since unlocking.
                    Log.screen.info("Wake-settle: displays unchanged since suspend — skipping restore")
                    self.exitWakeSettleWindow()
                    return
                }
                // Heuristic never matched within the timeout — best-effort restore
                // against whatever the detector currently reports.
                Log.screen.info("Wake-settle timeout: restoring against current profile=\(key)")
                self.restoreInWakeSettle(profileKey: key)
            case .awaitingExit:
                // Cooldown may have absorbed a genuine change (a display plugged in, or the
                // same displays settling on a different mode or arrangement), or a begin
                // pulse may have cut the last restore short. Restore once more instead of
                // exiting with a stale or half-finished layout.
                let current = self.screenDetector.profileKey
                let fingerprint = self.screenDetector.topologyFingerprint
                let reason: String?
                if current != self.wakeSettleLastRestoredKey {
                    reason = "profile drifted to \(current)"
                } else if fingerprint != self.wakeSettleLastRestoredFingerprint {
                    reason = "display geometry changed"
                } else if self.wakeSettleRestoreInterrupted {
                    reason = "previous restore was interrupted"
                } else {
                    reason = nil
                }
                if !current.isEmpty, let reason {
                    Log.screen.info("Wake-settle cooldown elapsed (\(reason)) — restoring before exit")
                    self.restoreInWakeSettle(profileKey: current)
                } else {
                    Log.screen.info("Wake-settle cooldown elapsed — exiting wake-settle window")
                    self.exitWakeSettleWindow()
                }
            }
        }
    }

    private func exitWakeSettleWindow() {
        isInWakeSettleWindow = false
        isScreenReconfiguring = false
        didSettle()
    }

    /// Best-effort save of the current (pre-change) profile the moment a display
    /// reconfiguration is announced, while windows are still where the user left them.
    func handleScreenWillChange() {
        noteDisplayEventIfSettling()
        let interruptedRestore = snapshotStore.cancelRestore()
        let interruptedRules = ruleApplyService.cancelPendingWork()
        if isInWakeSettleWindow, wakeSettleStage == .awaitingExit, interruptedRestore || interruptedRules {
            wakeSettleRestoreInterrupted = true
        }
        screenSaveGeneration &+= 1
        guard !isScreenReconfiguring else {
            lastReconfigActivityAt = now()
            return
        }
        autoSaveCurrentLayout(trigger: .screenWillChange)
        markScreenReconfiguring()
    }

    func handleScreenChange(newProfileKey: String) {
        snapshotStore.cancelRestore()
        ruleApplyService.cancelPendingWork()
        markScreenReconfiguring()
        screenSaveGeneration &+= 1
        guard !powerMonitor.isSuspended else { return }
        scheduleDelayedAutoSave(trigger: .screenChange, delay: Constants.Timing.screenChangeAutoSaveDelay)
        guard ensureAccessibilityPermission(promptIfNeeded: false) else { return }

        let context = screenSessionService.recordScreenChange(to: newProfileKey)
        Log.general.info("Screen change: '\(context.oldProfileKey)' -> '\(context.newProfileKey)' (\(context.newProfileLabel))")

        let restoreResult = snapshotService.restoreLayout(
            profileKey: context.newProfileKey,
            profileLabel: context.newProfileLabel
        )
        switch restoreResult {
        case .restored:
            if let moveCount = ruleApplyService.applyRulesIfAvailable() {
                Log.rule.info("Applied \(moveCount) rule moves after snapshot restore")
            }
            lastAction = restoreResult.statusMessage
        case .missing:
            _ = ruleApplyService.applyFallbackRulesIfAvailable()
            lastAction = "New screen combo: \(context.newProfileLabel)"
            Log.snapshot.info("No snapshot for '\(context.newProfileLabel)', used rules as fallback")
        }

    }

    private func markScreenReconfiguring() {
        isScreenReconfiguring = true
        lastReconfigActivityAt = now()
    }

    private func noteDisplayEventIfSettling() {
        if powerMonitor.isSuspended || isInWakeSettleWindow {
            sawDisplayEventSinceSuspend = true
        }
    }

    /// Displays finished changing and saves are allowed again.
    private func didSettle() {
        guard !deferredAppLaunches.isEmpty else { return }
        let launches = deferredAppLaunches
        deferredAppLaunches.removeAll()
        Log.rule.info("Replaying \(launches.count) app launches deferred while displays were changing")
        for launch in launches {
            handleAppLaunch(bundleId: launch.bundleId, appName: launch.appName)
        }
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
        if powerMonitor.isSuspended || isScreenReconfiguring || isInWakeSettleWindow {
            // Moving windows now would race the display change; apply the rule once it settles.
            if !deferredAppLaunches.contains(where: { $0.bundleId == bundleId && $0.appName == appName }) {
                deferredAppLaunches.append((bundleId, appName))
                if deferredAppLaunches.count > 20 { deferredAppLaunches.removeFirst() }
            }
            return
        }
        guard ensureAccessibilityPermission(promptIfNeeded: false) else { return }

        ruleApplyService.handleAppLaunch(bundleId: bundleId, appName: appName) { [weak self] result in
            guard let self, let result else { return }

            self.lastAction = result.statusMessage
            self.scheduleDelayedAutoSave(trigger: .appLaunch, delay: Constants.Timing.appLaunchAutoSaveDelay)
        }
    }

    private func setupAutoSaveTimer() {
        let timer = Timer(timeInterval: Constants.Timing.layoutAutoSaveInterval, repeats: true) { [weak self] _ in
            self?.performPeriodicTick()
        }
        timer.tolerance = Constants.Timing.layoutAutoSaveTolerance
        RunLoop.main.add(timer, forMode: .common)
        autoSaveTimer = timer
    }

    /// Windows rarely move without mouse or keyboard input, so the periodic AX sweep only
    /// runs when there has been input since the last capture. Display changes, wake and
    /// app launches have their own saves and do not depend on this.
    private func performPeriodicTick() {
        if let lastCapture = lastLayoutCaptureAt {
            let lastInput = now().addingTimeInterval(-secondsSinceLastUserInput())
            guard lastInput >= lastCapture else { return }
        }
        autoSaveCurrentLayout(trigger: .periodic)
    }

    func performPeriodicTickForTesting() {
        performPeriodicTick()
    }

    private func scheduleDelayedAutoSave(trigger: SnapshotService.Trigger, delay: TimeInterval) {
        let generation = screenSaveGeneration
        let profileKey = screenDetector.profileKey
        scheduleAfter(delay) { [weak self] in
            guard let self, self.screenSaveGeneration == generation,
                  self.screenDetector.profileKey == profileKey else { return }
            if trigger == .screenChange, self.isScreenReconfiguring {
                self.isScreenReconfiguring = false
                if !self.isInWakeSettleWindow { self.didSettle() }
            }
            self.autoSaveCurrentLayout(trigger: trigger)
        }
    }

    func performPeriodicAutoSaveForTesting() {
        autoSaveCurrentLayout(trigger: .periodic)
    }

    private func autoSaveCurrentLayout(trigger: SnapshotService.Trigger) {
        // Never persist layouts while the system is suspended (sleep/lock), still settling
        // after wake, or mid display change — captures taken in those windows are the
        // transitional states macOS produces, and saving them overwrites good snapshots.
        if let reason = saveBlockReason() {
            Log.snapshot.info("Skipped snapshot save [\(trigger.logLabel)]: \(reason)")
            return
        }
        _ = captureLayout(trigger: trigger, force: false)
    }

    private func saveBlockReason() -> String? {
        if powerMonitor.isSuspended { return "system suspended" }
        if isInWakeSettleWindow { return "settling after wake" }
        guard isScreenReconfiguring else { return nil }
        if let lastActivity = lastReconfigActivityAt,
           now().timeIntervalSince(lastActivity) > Constants.Timing.reconfigWatchdogDelay {
            Log.screen.warning("Display reconfiguration flag still set \(Int(now().timeIntervalSince(lastActivity)))s after the last display event; clearing it")
            isScreenReconfiguring = false
            didSettle()
            return nil
        }
        return "displays are reconfiguring"
    }

    @discardableResult
    private func captureLayout(trigger: SnapshotService.Trigger, force: Bool) -> SnapshotService.SaveResult? {
        guard ensureAccessibilityPermission(promptIfNeeded: false) else { return nil }
        let startedAt = now()
        // The pre-change save races WindowServer; drop it if the displays already changed.
        let validate: (() -> Bool)? = trigger == .screenWillChange
            ? { [screenDetector] in screenDetector.liveGeometryMatchesScreens() }
            : nil
        let result = snapshotService.saveCurrentLayout(trigger: trigger, force: force, validate: validate)
        switch result {
        case .saved, .unchanged, .noWindows:
            lastLayoutCaptureAt = startedAt
        case .discarded, .deferred, .failed:
            // Nothing usable was recorded; let the next periodic tick try again.
            break
        }
        return result
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

import Cocoa
import Combine

/// Tracks the macOS power / lock-screen state so the orchestrator can suspend snapshot
/// restores during sleep + lock and re-fire a single restore once the system settles.
///
/// During wake-from-sleep / unlock, macOS streams several `CGDisplayReconfiguration`
/// callbacks as displays come back online one by one. Without gating, each transient
/// state triggers its own restore and the windows visibly jump around — and may end up
/// in the wrong place because some of those restores ran against a partial display set.
final class PowerStateMonitor {
    private let suspendedSubject = CurrentValueSubject<Bool, Never>(false)
    private let resumedSubject = PassthroughSubject<Void, Never>()

    private var screensAreSleeping = false
    private var screenIsLocked = false
    private var observers: [NSObjectProtocol] = []
    private let workspaceCenter: NotificationCenter
    private let distributedCenter: DistributedNotificationCenter

    var isSuspended: Bool { suspendedSubject.value }

    /// Emits `true` when the system enters a suspended state (sleep or lock) and
    /// `false` when it leaves it. De-duplicated; only state transitions are emitted.
    var onSuspendedChanged: AnyPublisher<Bool, Never> {
        suspendedSubject.removeDuplicates().eraseToAnyPublisher()
    }

    /// Emits once each time the system transitions back to active.
    var onResumed: AnyPublisher<Void, Never> {
        resumedSubject.eraseToAnyPublisher()
    }

    init(workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
         distributedCenter: DistributedNotificationCenter = DistributedNotificationCenter.default(),
         observe: Bool = true) {
        self.workspaceCenter = workspaceCenter
        self.distributedCenter = distributedCenter
        if observe {
            registerObservers()
        }
    }

    deinit {
        for token in observers {
            workspaceCenter.removeObserver(token)
            distributedCenter.removeObserver(token)
        }
    }

    private func registerObservers() {
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.setScreensSleeping(true) })

        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.setScreensSleeping(false) })

        // Screen lock / unlock are CGSession events delivered via the distributed
        // notification center under these undocumented-but-stable names.
        observers.append(distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.setScreenLocked(true) })

        observers.append(distributedCenter.addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in self?.setScreenLocked(false) })
    }

    // MARK: - Test hooks

    func simulateScreensSleeping(_ sleeping: Bool) { setScreensSleeping(sleeping) }
    func simulateScreenLocked(_ locked: Bool) { setScreenLocked(locked) }

    // MARK: - Internal

    private func setScreensSleeping(_ sleeping: Bool) {
        guard screensAreSleeping != sleeping else { return }
        screensAreSleeping = sleeping
        Log.screen.info("Power: screensDidSleep=\(sleeping)")
        recompute()
    }

    private func setScreenLocked(_ locked: Bool) {
        guard screenIsLocked != locked else { return }
        screenIsLocked = locked
        Log.screen.info("Power: screenIsLocked=\(locked)")
        recompute()
    }

    private func recompute() {
        let suspended = screensAreSleeping || screenIsLocked
        let was = suspendedSubject.value
        guard was != suspended else { return }
        suspendedSubject.send(suspended)
        if was, !suspended {
            resumedSubject.send()
        }
    }
}

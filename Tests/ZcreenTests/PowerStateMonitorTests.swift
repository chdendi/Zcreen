import XCTest
import Combine
@testable import Zcreen

final class PowerStateMonitorTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testStartsActive() {
        let monitor = PowerStateMonitor(observe: false)
        XCTAssertFalse(monitor.isSuspended)
    }

    func testEntersSuspendedWhenScreensSleep() {
        let monitor = PowerStateMonitor(observe: false)
        monitor.simulateScreensSleeping(true)
        XCTAssertTrue(monitor.isSuspended)
    }

    func testEntersSuspendedWhenScreenLocked() {
        let monitor = PowerStateMonitor(observe: false)
        monitor.simulateScreenLocked(true)
        XCTAssertTrue(monitor.isSuspended)
    }

    func testRemainsSuspendedUntilBothLockAndSleepClear() {
        let monitor = PowerStateMonitor(observe: false)
        monitor.simulateScreenLocked(true)
        monitor.simulateScreensSleeping(true)
        XCTAssertTrue(monitor.isSuspended)

        monitor.simulateScreensSleeping(false)
        XCTAssertTrue(monitor.isSuspended, "Should remain suspended while still locked")

        monitor.simulateScreenLocked(false)
        XCTAssertFalse(monitor.isSuspended)
    }

    func testEmitsResumeOnlyOnTransitionFromSuspended() {
        let monitor = PowerStateMonitor(observe: false)
        var resumeCount = 0
        monitor.onResumed.sink { resumeCount += 1 }.store(in: &cancellables)

        // No transition yet — never suspended.
        monitor.simulateScreensSleeping(false)
        XCTAssertEqual(resumeCount, 0)

        monitor.simulateScreensSleeping(true)
        monitor.simulateScreensSleeping(false)
        XCTAssertEqual(resumeCount, 1)

        // Lock + unlock cycle should fire another resume.
        monitor.simulateScreenLocked(true)
        monitor.simulateScreenLocked(false)
        XCTAssertEqual(resumeCount, 2)
    }

    func testDeduplicatesRedundantSuspendNotifications() {
        let monitor = PowerStateMonitor(observe: false)
        var transitions: [Bool] = []
        monitor.onSuspendedChanged
            .dropFirst() // initial value
            .sink { transitions.append($0) }
            .store(in: &cancellables)

        monitor.simulateScreensSleeping(true)
        monitor.simulateScreensSleeping(true) // no-op
        monitor.simulateScreenLocked(true)    // already suspended; suspended stays true
        monitor.simulateScreensSleeping(false) // still locked → still suspended
        monitor.simulateScreenLocked(false)    // now resumes

        XCTAssertEqual(transitions, [true, false])
    }
}

import XCTest
import Combine
@testable import Zcreen

final class ScreenDetectorTests: XCTestCase {
    func testCompletionWithNoPerDisplayChangesStillEndsConfiguration() {
        let detector = ScreenDetector(shouldRegisterCallback: false)
        let changed = expectation(description: "Configuration completed")
        let subscription = detector.onScreensChanged.sink { _ in changed.fulfill() }
        detector.handleDisplayChange(flags: .beginConfigurationFlag)
        detector.handleDisplayChange(flags: [])
        wait(for: [changed], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    func testNewBeginCancelsEarlierCompletionUntilNextQuietInterval() {
        let detector = ScreenDetector(shouldRegisterCallback: false)
        let premature = expectation(description: "No event from interrupted configuration")
        premature.isInverted = true
        let completed = expectation(description: "New configuration completed")
        var awaitingCompletion = false
        let subscription = detector.onScreensChanged.sink { _ in
            if awaitingCompletion { completed.fulfill() } else { premature.fulfill() }
        }
        detector.handleDisplayChange(flags: .setModeFlag)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            detector.handleDisplayChange(flags: .beginConfigurationFlag)
        }
        wait(for: [premature], timeout: 0.9)
        awaitingCompletion = true
        detector.handleDisplayChange(flags: .mirrorFlag)
        wait(for: [completed], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    func testModeChangeEmitsSettledScreenChange() {
        let detector = ScreenDetector(shouldRegisterCallback: false)
        let changed = expectation(description: "Display mode change")
        let subscription = detector.onScreensChanged.sink { _ in changed.fulfill() }
        detector.handleDisplayChange(flags: .setModeFlag)
        wait(for: [changed], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    func testBeginPulseAloneDoesNotRestoreBeforeConfigurationCompletes() {
        let detector = ScreenDetector(shouldRegisterCallback: false)
        let changed = expectation(description: "No restore on begin")
        changed.isInverted = true
        let subscription = detector.onScreensChanged.sink { _ in changed.fulfill() }
        detector.handleDisplayChange(flags: .beginConfigurationFlag)
        wait(for: [changed], timeout: 0.7)
        withExtendedLifetime(subscription) {}
    }
}

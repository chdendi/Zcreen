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

    func testFingerprintTracksGeometryThatProfileKeyIgnores() {
        let detector = ScreenDetector(shouldRegisterCallback: false)
        detector.setStateForTesting(screens: [screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))])
        let key = detector.profileKey
        let fingerprint = detector.topologyFingerprint

        detector.setStateForTesting(screens: [screen(frame: CGRect(x: 0, y: 0, width: 1800, height: 1169))])

        XCTAssertEqual(detector.profileKey, key, "Same physical display, same profile")
        XCTAssertNotEqual(detector.topologyFingerprint, fingerprint)
    }

    func testLiveGeometryCheckDetectsDisplaysThatAlreadyChanged() {
        let detector = ScreenDetector(shouldRegisterCallback: false)
        let builtIn = screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        detector.setStateForTesting(screens: [builtIn])
        XCTAssertTrue(detector.liveGeometryMatchesScreens())

        detector.setStateForTesting(screens: [builtIn], liveGeometry: [
            .init(displayID: builtIn.displayID, frame: builtIn.frame),
            .init(displayID: 7, frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440)),
        ])
        XCTAssertFalse(detector.liveGeometryMatchesScreens())

        detector.setStateForTesting(screens: [builtIn], liveGeometry: [])
        XCTAssertTrue(detector.liveGeometryMatchesScreens(), "Unknown live state must not block saves")
    }

    private func screen(frame: CGRect) -> ScreenInfo {
        ScreenInfo(displayID: 1, name: "Built-in Retina Display", frame: frame, isBuiltIn: true,
                   position: .single, vendorID: 1, modelID: 101, serialNumber: 1001, persistentID: "uuid-builtin")
    }
}

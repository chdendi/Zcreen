import XCTest
@testable import Zcreen

final class CaffeinateManagerTests: XCTestCase {
    func testIndefiniteActivationStaysActiveUntilExplicitDeactivation() throws {
        let manager = CaffeinateManager(caffeinateExecutableURL: URL(fileURLWithPath: "/usr/bin/true"))

        manager.activateIndefinitely()

        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(manager.isIndefinite)
        XCTAssertEqual(manager.remainingMinutes, 0)

        manager.deactivate()

        XCTAssertFalse(manager.isActive)
        XCTAssertFalse(manager.isIndefinite)
    }
}

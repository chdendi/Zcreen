import XCTest
import CoreGraphics
@testable import Zcreen

final class WindowManagerTests: XCTestCase {

    func testFallbackOriginClampsOversizedLeftHalfWithinBounds() {
        let targetFrame = CGRect(x: 0, y: 33, width: 753, height: 898)
        let bounds = CGRect(x: 0, y: 33, width: 1512, height: 898)

        let origin = WindowManager.fallbackOrigin(
            actualSize: CGSize(width: 940, height: 897),
            targetFrame: targetFrame,
            bounds: bounds
        )

        XCTAssertEqual(origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(origin.y, 33.5, accuracy: 0.001)
    }

    func testFallbackOriginClampsOversizedRightHalfWithinBounds() {
        let targetFrame = CGRect(x: 759, y: 33, width: 753, height: 898)
        let bounds = CGRect(x: 0, y: 33, width: 1512, height: 898)

        let origin = WindowManager.fallbackOrigin(
            actualSize: CGSize(width: 940, height: 897),
            targetFrame: targetFrame,
            bounds: bounds
        )

        XCTAssertEqual(origin.x, 572, accuracy: 0.001)
        XCTAssertEqual(origin.y, 33.5, accuracy: 0.001)
    }

    func testFallbackOriginKeepsCenteredOriginWhenWindowFitsBounds() {
        let targetFrame = CGRect(x: 100, y: 100, width: 500, height: 400)
        let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

        let origin = WindowManager.fallbackOrigin(
            actualSize: CGSize(width: 300, height: 200),
            targetFrame: targetFrame,
            bounds: bounds
        )

        XCTAssertEqual(origin.x, 200, accuracy: 0.001)
        XCTAssertEqual(origin.y, 200, accuracy: 0.001)
    }

    func testFallbackOriginPreservesPreviousCenteringWhenBoundsAreUnknown() {
        let targetFrame = CGRect(x: 0, y: 33, width: 753, height: 898)

        let origin = WindowManager.fallbackOrigin(
            actualSize: CGSize(width: 940, height: 897),
            targetFrame: targetFrame,
            bounds: nil
        )

        XCTAssertEqual(origin.x, -93.5, accuracy: 0.001)
        XCTAssertEqual(origin.y, 33.5, accuracy: 0.001)
    }
}

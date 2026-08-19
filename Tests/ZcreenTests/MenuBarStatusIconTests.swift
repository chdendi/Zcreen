import XCTest
@testable import Zcreen

final class MenuBarStatusIconTests: XCTestCase {
    func testSymbolNameReflectsCaffeinateState() {
        XCTAssertEqual(MenuBarStatusIcon.symbolName(isActive: false), "rectangle.3.group")
        XCTAssertEqual(MenuBarStatusIcon.symbolName(isActive: true), "cup.and.saucer.fill")
    }
}

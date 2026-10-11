import XCTest
@testable import Zcreen

final class WindowMatcherTests: XCTestCase {

    func testWeakMatchIsSkippedWhenOnlyOneOfSeveralSavedWindowsAppears() {
        let saved = [
            makeSnapshot(title: nil, width: 800, height: 600, role: nil, subrole: nil),
            makeSnapshot(title: nil, width: 800, height: 600, role: nil, subrole: nil),
        ]
        let running = [makeCandidate(title: nil, width: 800, height: 600, role: nil, subrole: nil)]
        XCTAssertTrue(WindowMatcher.match(saved: saved, running: running).isEmpty)
    }

    func testDoesNotAssignUnrelatedWindowsWithNegativeScores() {
        let saved = [makeSnapshot(title: "Old project", width: 1200, height: 900, screenKey: "old-screen")]
        let running = [makeCandidate(title: "New document", width: 600, height: 400,
                                     screenName: "Other", screenKey: "other-screen")]
        XCTAssertTrue(WindowMatcher.match(saved: saved, running: running).isEmpty)
    }

    func testMatchesWindowsByExactTitleEvenWhenOrderDiffers() {
        let saved = [
            makeSnapshot(title: "Inbox", width: 900, height: 700),
            makeSnapshot(title: "Calendar", width: 800, height: 600),
        ]
        let running = [
            makeCandidate(title: "Calendar", width: 800, height: 600),
            makeCandidate(title: "Inbox", width: 900, height: 700),
        ]

        let assignments = WindowMatcher.match(saved: saved, running: running)

        XCTAssertEqual(assignments.count, 2)
        XCTAssertEqual(assignments.first(where: { $0.savedIndex == 0 })?.runningIndex, 1)
        XCTAssertEqual(assignments.first(where: { $0.savedIndex == 1 })?.runningIndex, 0)
    }

    func testFallsBackToRoleAndSizeForUntitledWindows() {
        let saved = [
            makeSnapshot(title: nil, width: 1200, height: 900, role: "AXWindow", subrole: "AXStandardWindow"),
            makeSnapshot(title: nil, width: 700, height: 500, role: "AXWindow", subrole: "AXStandardWindow"),
        ]
        let running = [
            makeCandidate(title: nil, width: 700, height: 500, role: "AXWindow", subrole: "AXStandardWindow"),
            makeCandidate(title: nil, width: 1200, height: 900, role: "AXWindow", subrole: "AXStandardWindow"),
        ]

        let assignments = WindowMatcher.match(saved: saved, running: running)

        XCTAssertEqual(assignments.count, 2)
        XCTAssertEqual(assignments.first(where: { $0.savedIndex == 0 })?.runningIndex, 1)
        XCTAssertEqual(assignments.first(where: { $0.savedIndex == 1 })?.runningIndex, 0)
    }

    func testSameTitleOnDifferentScreensIsResolvedByScreenKey() {
        // Two saved windows with identical titles but on different physical displays.
        // Without screenKey, the matcher could swap them; screenKey should pin each to its display.
        let saved = [
            makeSnapshot(title: "Notes", width: 800, height: 600, screenName: "Built-in",
                         screenKey: "uuid-builtin"),
            makeSnapshot(title: "Notes", width: 800, height: 600, screenName: "Dell U2723QE",
                         screenKey: "uuid-dell"),
        ]
        let running = [
            makeCandidate(title: "Notes", width: 800, height: 600, screenName: "Dell U2723QE",
                          screenKey: "uuid-dell"),
            makeCandidate(title: "Notes", width: 800, height: 600, screenName: "Built-in",
                          screenKey: "uuid-builtin"),
        ]

        let assignments = WindowMatcher.match(saved: saved, running: running)

        XCTAssertEqual(assignments.count, 2)
        XCTAssertEqual(assignments.first(where: { $0.savedIndex == 0 })?.runningIndex, 1)
        XCTAssertEqual(assignments.first(where: { $0.savedIndex == 1 })?.runningIndex, 0)
    }

    func testScreenKeyMismatchPenalizedRelativeToNoScreenKey() {
        // Saved has a screenKey; one running candidate matches it, another has a different key.
        // The matching screenKey should win even though the other candidate has identical other signals.
        let saved = makeSnapshot(title: "Doc", width: 800, height: 600, screenKey: "uuid-a")
        let running = [
            makeCandidate(title: "Doc", width: 800, height: 600, screenKey: "uuid-b"),
            makeCandidate(title: "Doc", width: 800, height: 600, screenKey: "uuid-a"),
        ]

        let assignments = WindowMatcher.match(saved: [saved], running: running)

        XCTAssertEqual(assignments.count, 1)
        XCTAssertEqual(assignments[0].runningIndex, 1)
    }

    func testLowConfidenceWhenOnlyWeakSignalsExist() {
        let saved = [
            makeSnapshot(title: nil, width: 800, height: 600, role: nil, subrole: nil, screenName: "Unknown"),
        ]
        let running = [
            makeCandidate(title: nil, width: 800, height: 600, role: nil, subrole: nil, screenName: "Unknown"),
        ]

        let assignments = WindowMatcher.match(saved: saved, running: running)

        XCTAssertEqual(assignments.count, 1)
        XCTAssertTrue(assignments[0].isLowConfidence)
    }

    private func makeSnapshot(title: String?, width: Double, height: Double,
                              role: String? = "AXWindow", subrole: String? = "AXStandardWindow",
                              screenName: String = "Main", screenKey: String? = nil) -> WindowSnapshot {
        WindowSnapshot(
            bundleId: "com.test.app",
            appName: "Test App",
            windowTitle: title,
            frame: .init(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))),
            screenName: screenName,
            screenKey: screenKey,
            windowRole: role,
            windowSubrole: subrole
        )
    }

    private func makeCandidate(title: String?, width: CGFloat, height: CGFloat,
                               role: String? = "AXWindow", subrole: String? = "AXStandardWindow",
                               screenName: String = "Main", screenKey: String? = nil) -> WindowMatchCandidate {
        WindowMatchCandidate(
            title: title,
            frame: CGRect(x: 0, y: 0, width: width, height: height),
            screenName: screenName,
            screenKey: screenKey,
            role: role,
            subrole: subrole
        )
    }
}

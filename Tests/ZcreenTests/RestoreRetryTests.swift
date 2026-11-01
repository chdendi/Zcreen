import XCTest
import ApplicationServices
@testable import Zcreen

final class RestoreRetryTests: XCTestCase {
    private let savedFrame = CGRect(x: 20, y: 30, width: 600, height: 400)
    private let evictedFrame = CGRect(x: 200, y: 300, width: 500, height: 350)

    func testRetryMovesOnlyWindowsThatWereMissing() {
        let scheduler = RetryScheduler()
        let manager = RetryWindowManager()
        let a = window(bundle: "a", pid: 501)
        let b = window(bundle: "b", pid: 502)
        manager.windows = [a]
        let store = makeStore(scheduler: scheduler, running: ["a", "b"])
        store.restoreSnapshot(snapshot([saved("a"), saved("b")]), windowManager: manager,
                              windowFilter: WindowFilter(configuration: .empty))
        XCTAssertEqual(manager.moves, 1)
        manager.windows = [a, b]
        scheduler.runNext()
        XCTAssertEqual(manager.moves, 2, "An already restored window must not move again")
        scheduler.runNext() // verification pass
        XCTAssertTrue(scheduler.actions.isEmpty)
        XCTAssertFalse(store.isRestoreInFlight)
    }

    func testCancelPreventsScheduledRetryFromMovingWindows() {
        let scheduler = RetryScheduler()
        let manager = RetryWindowManager()
        let store = makeStore(scheduler: scheduler, running: ["a"])
        store.restoreSnapshot(snapshot([saved("a")]), windowManager: manager,
                              windowFilter: WindowFilter(configuration: .empty))
        XCTAssertTrue(store.cancelRestore(), "Cancel must report the in-flight restore it stopped")
        XCTAssertFalse(store.cancelRestore())
        manager.windows = [window(bundle: "a", pid: 501)]
        scheduler.runNext()
        XCTAssertEqual(manager.moves, 0)
    }

    func testPartialAppRetryDoesNotReuseAnAlreadyMovedWindow() {
        let scheduler = RetryScheduler()
        let manager = RetryWindowManager()
        let a = window(bundle: "a", pid: 501)
        manager.windows = [a]
        let store = makeStore(scheduler: scheduler, running: ["a"])
        store.restoreSnapshot(snapshot([saved("a"), saved("a", title: "Second")]), windowManager: manager,
                              windowFilter: WindowFilter(configuration: .empty))
        XCTAssertEqual(manager.moves, 1)
        scheduler.runNext()
        XCTAssertEqual(manager.moves, 1)
        manager.windows = [a, window(bundle: "a", pid: 502, title: "Second")]
        scheduler.runNext()
        XCTAssertEqual(manager.moves, 2)
    }

    func testWindowAlreadyAtTargetIsNotMoved() {
        let scheduler = RetryScheduler()
        let manager = RetryWindowManager()
        manager.windows = [window(bundle: "a", pid: 501, frame: savedFrame.offsetBy(dx: 1, dy: -1))]
        let store = makeStore(scheduler: scheduler, running: ["a"])
        var outcome: RestoreOutcome?
        store.restoreSnapshot(snapshot([saved("a")]), windowManager: manager,
                              windowFilter: WindowFilter(configuration: .empty)) { outcome = $0 }
        XCTAssertEqual(manager.moves, 0)
        XCTAssertTrue(scheduler.actions.isEmpty, "Nothing moved, so there is nothing to verify")
        XCTAssertEqual(outcome?.placedCount, 1)
        XCTAssertTrue(outcome?.isComplete == true)
    }

    func testVerificationReappliesDriftedWindowAndReportsWhatStillFailed() throws {
        let scheduler = RetryScheduler()
        let manager = RetryWindowManager()
        let a = window(bundle: "a", pid: 501)
        manager.windows = [a]
        // The app keeps the window where macOS left it no matter what we set.
        manager.frameOverride = evictedFrame
        let store = makeStore(scheduler: scheduler, running: ["a"])
        var outcome: RestoreOutcome?
        store.restoreSnapshot(snapshot([saved("a")]), windowManager: manager,
                              windowFilter: WindowFilter(configuration: .empty)) { outcome = $0 }
        XCTAssertEqual(manager.moves, 1)
        XCTAssertNil(outcome)
        XCTAssertTrue(store.isRestoreInFlight)

        scheduler.runNext()

        XCTAssertEqual(manager.moves, 2, "A drifted window gets one more move")
        let result = try XCTUnwrap(outcome)
        XCTAssertEqual(result.drifted.count, 1)
        XCTAssertEqual(result.drifted.first?.frame, evictedFrame)
        XCTAssertEqual(result.placedCount, 0)
        XCTAssertFalse(store.isRestoreInFlight)
    }

    func testIdentityPairsWindowWhoseTitleChanged() throws {
        let scheduler = RetryScheduler()
        let manager = RetryWindowManager()
        let first = window(bundle: "a", pid: 501, title: "Tab now showing something else")
        let second = window(bundle: "a", pid: 502, title: "Another tab")
        manager.windows = [first, second]
        let store = makeStore(scheduler: scheduler, running: ["a"])
        let savedFirst = saved("a", title: "GitHub", frame: CGRect(x: 0, y: 30, width: 900, height: 700))
        let savedSecond = saved("a", title: "Docs", frame: CGRect(x: 900, y: 30, width: 900, height: 700))
        store.rememberIdentities(profileKey: "main", windows: [savedFirst, savedSecond],
                                 elements: [first.axWindow, second.axWindow])

        store.restoreSnapshot(snapshot([savedFirst, savedSecond]), windowManager: manager,
                              windowFilter: WindowFilter(configuration: .empty))

        XCTAssertEqual(manager.moved.count, 2, "Changed titles must not block windows known by identity")
        let firstTarget = try XCTUnwrap(manager.moved.first { CFEqual($0.window, first.axWindow) }).frame
        let secondTarget = try XCTUnwrap(manager.moved.first { CFEqual($0.window, second.axWindow) }).frame
        XCTAssertEqual(firstTarget, savedFirst.frame.cgRect)
        XCTAssertEqual(secondTarget, savedSecond.frame.cgRect)
    }

    func testOutcomeListsUnresolvedEntriesAndUnmatchedWindowsOfTheSameApp() throws {
        let scheduler = RetryScheduler()
        let manager = RetryWindowManager()
        // Two untitled windows the matcher cannot tell apart, plus a second app that matches.
        let unknownA = window(bundle: "a", pid: 501, title: nil)
        let unknownB = window(bundle: "a", pid: 502, title: nil)
        let other = window(bundle: "b", pid: 503)
        manager.windows = [unknownA, unknownB, other]
        let store = makeStore(scheduler: scheduler, running: ["a", "b"])
        var outcome: RestoreOutcome?
        store.restoreSnapshot(snapshot([saved("a", title: "Left"), saved("a", title: "Right"), saved("b")]),
                              windowManager: manager, windowFilter: WindowFilter(configuration: .empty)) { outcome = $0 }
        while !scheduler.actions.isEmpty { scheduler.runNext() }

        let result = try XCTUnwrap(outcome)
        XCTAssertEqual(Set(result.unresolved.compactMap(\.windowTitle)), ["Left", "Right"])
        XCTAssertEqual(result.orphans.count, 2)
        XCTAssertTrue(result.orphans.allSatisfy { $0.bundleId == "a" })
        XCTAssertEqual(result.placedCount, 1)
    }

    private func makeStore(scheduler: RetryScheduler, running: Set<String>) -> LayoutSnapshotStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return LayoutSnapshotStore(snapshotDirectory: directory, loadExisting: false,
                                   scheduleAfter: scheduler.schedule, runningBundleIds: { running })
    }
    private func snapshot(_ windows: [WindowSnapshot]) -> LayoutSnapshot {
        LayoutSnapshot(profileKey: "main", profileLabel: "Main", timestamp: Date(), windows: windows)
    }
    private func saved(_ bundle: String, title: String = "Document", frame: CGRect? = nil) -> WindowSnapshot {
        WindowSnapshot(bundleId: bundle, appName: bundle, windowTitle: title,
            frame: .init(frame ?? savedFrame), screenName: "Main",
            windowRole: "AXWindow", windowSubrole: "AXStandardWindow")
    }
    private func window(bundle: String, pid: pid_t, title: String? = "Document", frame: CGRect? = nil) -> WindowManager.WindowInfo {
        WindowManager.WindowInfo(pid: pid, bundleId: bundle, appName: bundle, title: title,
            role: "AXWindow", subrole: "AXStandardWindow", isMinimized: false,
            frame: frame ?? evictedFrame, axWindow: AXUIElementCreateApplication(pid))
    }
}

private final class RetryScheduler {
    var actions: [() -> Void] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) { actions.append(action) }
    func runNext() { if !actions.isEmpty { actions.removeFirst()() } }
}
private final class RetryWindowManager: WindowManager {
    var windows: [WindowInfo] = []
    var frameOverride: CGRect?
    private(set) var moved: [(window: AXUIElement, frame: CGRect)] = []
    var moves: Int { moved.count }
    override func getAllWindows() -> [WindowInfo] { windows }
    override func getWindows(bundleIds: Set<String>) -> [WindowInfo] {
        windows.filter { bundleIds.contains($0.bundleId ?? "") }
    }
    override func moveWindow(_ window: AXUIElement, toFrame frame: CGRect) { moved.append((window, frame)) }
    /// Without an override, a window reads back wherever it was last moved.
    override func frame(of window: AXUIElement) -> CGRect? {
        frameOverride ?? moved.last { CFEqual($0.window, window) }?.frame
    }
}

import XCTest
import ApplicationServices
@testable import Zcreen

final class RestoreRetryTests: XCTestCase {
    func testRetryMovesOnlyWindowsThatWereMissing() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = RetryScheduler()
        let manager = RetryWindowManager()
        let a = window(bundle: "a", pid: 501)
        let b = window(bundle: "b", pid: 502)
        manager.windows = [a]
        let store = LayoutSnapshotStore(snapshotDirectory: directory, loadExisting: false,
            scheduleAfter: scheduler.schedule, runningBundleIds: { ["a", "b"] })
        store.restoreSnapshot(snapshot([saved("a"), saved("b")]), windowManager: manager,
                              excludeBundleIds: [], windowFilter: WindowFilter(configuration: .empty))
        XCTAssertEqual(manager.moves, 1)
        manager.windows = [a, b]
        scheduler.runNext()
        XCTAssertEqual(manager.moves, 2, "An already restored window must not move again")
        XCTAssertTrue(scheduler.actions.isEmpty)
    }

    func testCancelPreventsScheduledRetryFromMovingWindows() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = RetryScheduler()
        let manager = RetryWindowManager()
        let store = LayoutSnapshotStore(snapshotDirectory: directory, loadExisting: false,
            scheduleAfter: scheduler.schedule, runningBundleIds: { ["a"] })
        store.restoreSnapshot(snapshot([saved("a")]), windowManager: manager,
                              excludeBundleIds: [], windowFilter: WindowFilter(configuration: .empty))
        store.cancelRestore()
        manager.windows = [window(bundle: "a", pid: 501)]
        scheduler.runNext()
        XCTAssertEqual(manager.moves, 0)
    }

    func testPartialAppRetryDoesNotReuseAnAlreadyMovedWindow() {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let scheduler = RetryScheduler()
        let manager = RetryWindowManager()
        let a = window(bundle: "a", pid: 501)
        manager.windows = [a]
        let store = LayoutSnapshotStore(snapshotDirectory: directory, loadExisting: false,
            scheduleAfter: scheduler.schedule, runningBundleIds: { ["a"] })
        store.restoreSnapshot(snapshot([saved("a"), saved("a", title: "Second")]), windowManager: manager,
                              excludeBundleIds: [], windowFilter: WindowFilter(configuration: .empty))
        XCTAssertEqual(manager.moves, 1)
        scheduler.runNext()
        XCTAssertEqual(manager.moves, 1)
        manager.windows = [a, window(bundle: "a", pid: 502, title: "Second")]
        scheduler.runNext()
        XCTAssertEqual(manager.moves, 2)
    }

    private func snapshot(_ windows: [WindowSnapshot]) -> LayoutSnapshot {
        LayoutSnapshot(profileKey: "main", profileLabel: "Main", timestamp: Date(), windows: windows)
    }
    private func saved(_ bundle: String, title: String = "Document") -> WindowSnapshot {
        WindowSnapshot(bundleId: bundle, appName: bundle, windowTitle: title,
            frame: .init(x: 20, y: 30, width: 600, height: 400), screenName: "Main",
            windowRole: "AXWindow", windowSubrole: "AXStandardWindow")
    }
    private func window(bundle: String, pid: pid_t, title: String = "Document") -> WindowManager.WindowInfo {
        WindowManager.WindowInfo(pid: pid, bundleId: bundle, appName: bundle, title: title,
            role: "AXWindow", subrole: "AXStandardWindow", isMinimized: false,
            frame: CGRect(x: 20, y: 30, width: 600, height: 400), axWindow: AXUIElementCreateApplication(pid))
    }
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private final class RetryScheduler {
    var actions: [() -> Void] = []
    func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) { actions.append(action) }
    func runNext() { if !actions.isEmpty { actions.removeFirst()() } }
}
private final class RetryWindowManager: WindowManager {
    var windows: [WindowInfo] = []
    var moves = 0
    override func getAllWindows() -> [WindowInfo] { windows }
    override func moveWindow(_ window: AXUIElement, toFrame frame: CGRect) { moves += 1 }
}

import XCTest
@testable import Zcreen

final class DiskSpaceSnapshotTests: XCTestCase {
    func testWarningIsStrictlyBelowTenPercent() throws {
        XCTAssertTrue(try XCTUnwrap(DiskSpaceSnapshot(availableBytes: 0, totalBytes: 100)).isLow)
        XCTAssertTrue(try XCTUnwrap(DiskSpaceSnapshot(availableBytes: 999, totalBytes: 10_000)).isLow)
        XCTAssertFalse(try XCTUnwrap(DiskSpaceSnapshot(availableBytes: 1000, totalBytes: 10_000)).isLow)
        XCTAssertFalse(try XCTUnwrap(DiskSpaceSnapshot(availableBytes: 1001, totalBytes: 10_000)).isLow)
        XCTAssertFalse(try XCTUnwrap(DiskSpaceSnapshot(availableBytes: 100, totalBytes: 100)).isLow)
        XCTAssertTrue(try XCTUnwrap(DiskSpaceSnapshot(availableBytes: 10, totalBytes: 101)).isLow)
        XCTAssertFalse(try XCTUnwrap(DiskSpaceSnapshot(availableBytes: 11, totalBytes: 101)).isLow)
    }

    func testLargeCapacitiesDoNotOverflowOrRoundAcrossThreshold() throws {
        let threshold = Int64.max / 10
        XCTAssertTrue(try XCTUnwrap(DiskSpaceSnapshot(availableBytes: threshold, totalBytes: .max)).isLow)
        XCTAssertFalse(try XCTUnwrap(DiskSpaceSnapshot(availableBytes: threshold + 1, totalBytes: .max)).isLow)
    }

    func testInvalidCapacityCannotProduceAWarning() {
        XCTAssertNil(DiskSpaceSnapshot(availableBytes: -1, totalBytes: 100))
        XCTAssertNil(DiskSpaceSnapshot(availableBytes: 0, totalBytes: 0))
        XCTAssertNil(DiskSpaceSnapshot(availableBytes: 0, totalBytes: -1))
        XCTAssertNil(DiskSpaceSnapshot(availableBytes: 101, totalBytes: 100))
    }
}

private final class DiskSpaceSource: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DiskSpaceSnapshot?
    private var calls = 0
    let holdFirst: Bool
    let firstStarted = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let firstFinished = DispatchSemaphore(value: 0)

    init(_ value: DiskSpaceSnapshot?, holdFirst: Bool = false) {
        self.value = value
        self.holdFirst = holdFirst
    }

    func set(_ value: DiskSpaceSnapshot?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func read() -> DiskSpaceSnapshot? {
        lock.lock()
        let value = value
        calls += 1
        let first = calls == 1
        lock.unlock()
        if first && holdFirst {
            firstStarted.signal()
            _ = releaseFirst.wait(timeout: .now() + 2)
            firstFinished.signal()
        }
        return value
    }
}

@MainActor
final class DiskSpaceMonitorTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Capacity refresh did not finish")
    }

    func testRefreshShowsAndClearsWarningAsCapacityChangesOrBecomesUnknown() async throws {
        let low = try XCTUnwrap(DiskSpaceSnapshot(availableBytes: 9, totalBytes: 100))
        let enough = try XCTUnwrap(DiskSpaceSnapshot(availableBytes: 10, totalBytes: 100))
        let source = DiskSpaceSource(low)
        let monitor = DiskSpaceMonitor(startMonitoring: false, load: { source.read() })
        XCTAssertNil(monitor.snapshot)

        monitor.refresh()
        try await waitUntil { monitor.snapshot == low }
        XCTAssertTrue(try XCTUnwrap(monitor.snapshot).isLow)

        source.set(enough)
        monitor.refresh()
        try await waitUntil { monitor.snapshot == enough }
        XCTAssertFalse(try XCTUnwrap(monitor.snapshot).isLow)

        source.set(low)
        monitor.refresh()
        try await waitUntil { monitor.snapshot == low }
        source.set(nil)
        monitor.refresh()
        try await waitUntil { monitor.snapshot == nil }
    }

    func testOlderResponseCannotRestoreAnOutdatedWarning() async throws {
        let low = try XCTUnwrap(DiskSpaceSnapshot(availableBytes: 9, totalBytes: 100))
        let enough = try XCTUnwrap(DiskSpaceSnapshot(availableBytes: 10, totalBytes: 100))
        let source = DiskSpaceSource(low, holdFirst: true)
        defer { source.releaseFirst.signal() }
        let monitor = DiskSpaceMonitor(startMonitoring: false, load: { source.read() })
        monitor.refresh()
        let started = await Task.detached { source.firstStarted.wait(timeout: .now() + 2) }.value
        XCTAssertEqual(started, .success)

        source.set(enough)
        monitor.refresh()
        try await waitUntil { monitor.snapshot == enough }
        source.releaseFirst.signal()
        let finished = await Task.detached { source.firstFinished.wait(timeout: .now() + 2) }.value
        XCTAssertEqual(finished, .success)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(monitor.snapshot, enough)
    }
}

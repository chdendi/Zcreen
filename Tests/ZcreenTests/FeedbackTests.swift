import XCTest
@testable import Zcreen

final class FeedbackTests: XCTestCase {
    func testFiveTapsOpenFeedbackOnceAndPauseResetsCount() {
        var gesture = FeedbackGesture()
        let start = Date(timeIntervalSince1970: 100)
        for index in 0..<4 { XCTAssertFalse(gesture.tap(at: start.addingTimeInterval(Double(index) * 0.2))) }
        XCTAssertTrue(gesture.tap(at: start.addingTimeInterval(0.8)))
        XCTAssertFalse(gesture.tap(at: start.addingTimeInterval(1)))
        XCTAssertFalse(gesture.tap(at: start.addingTimeInterval(5)))
        for index in 1..<4 { XCTAssertFalse(gesture.tap(at: start.addingTimeInterval(5 + Double(index) * 0.2))) }
        XCTAssertTrue(gesture.tap(at: start.addingTimeInterval(5.8)))
    }

    func testReportContainsDescriptionAndOnlyRecentBoundedLogs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let recent = logs.appendingPathComponent("zcreen-20261011.log")
        try Data("abcdefghij".utf8).write(to: recent)
        let old = logs.appendingPathComponent("zcreen-20261001.log")
        try Data("old".utf8).write(to: old)
        let now = Date()
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3 * 86_400)], ofItemAtPath: old.path)
        try Data("secret".utf8).write(to: logs.appendingPathComponent("other.txt"))
        try FileManager.default.createSymbolicLink(at: logs.appendingPathComponent("zcreen-20261010.log"), withDestinationURL: recent)
        let builder = FeedbackReportBuilder(logsDirectory: logs, outputDirectory: root.appendingPathComponent("output"),
            version: "1.2.4", systemVersion: "macOS test", maximumLogBytes: 5)
        let report = try builder.build(description: "  Windows moved unexpectedly  ", includeLogs: true, now: now)
        XCTAssertEqual(report.attachedLogCount, 1)
        let content = report.directory.appendingPathComponent("Feedback")
        XCTAssertEqual(try Data(contentsOf: content.appendingPathComponent(recent.lastPathComponent)), Data("fghij".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: content.appendingPathComponent(old.lastPathComponent).path))
        XCTAssertTrue(report.body.contains("Windows moved unexpectedly"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: report.archive.path))
    }

    func testOptingOutOfLogsCreatesDescriptionOnlyPackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let builder = FeedbackReportBuilder(logsDirectory: root.appendingPathComponent("missing"), outputDirectory: root,
                                           version: "test", systemVersion: "test")
        let report = try builder.build(description: "A problem", includeLogs: false)
        XCTAssertEqual(report.attachedLogCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: report.directory.appendingPathComponent("Feedback").path), ["feedback.txt"])
    }

    func testEmptyDescriptionDoesNotCreatePackage() {
        let builder = FeedbackReportBuilder(logsDirectory: URL(fileURLWithPath: "/unused"),
            outputDirectory: URL(fileURLWithPath: "/unused"), version: "test", systemVersion: "test")
        XCTAssertThrowsError(try builder.build(description: "  \n", includeLogs: true))
    }
}

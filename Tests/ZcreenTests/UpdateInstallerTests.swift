import XCTest
@testable import Zcreen

final class UpdateInstallerTests: XCTestCase {
    func testPreparationCopiesAndRevalidatesBeforeTouchingCurrentApp() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try makeApp(root, "Current.app", contents: "old")
        let new = try makeApp(root, "New.app", contents: "new")
        var validated: [URL] = []
        let installer = UpdateInstaller { candidate, original in
            XCTAssertEqual(original, current)
            validated.append(candidate)
        }
        let prepared = try installer.prepare(newApp: new, currentApp: current)
        XCTAssertEqual(validated, [new, prepared.replacement])
        XCTAssertEqual(try readApp(current), "old")
        XCTAssertEqual(try readApp(prepared.replacement), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.backup.path))
    }

    func testFailedStagedValidationPreservesCurrentAppAndCleansStaging() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try makeApp(root, "Current.app", contents: "old")
        let new = try makeApp(root, "New.app", contents: "new")
        var calls = 0
        let installer = UpdateInstaller { _, _ in
            calls += 1
            if calls == 2 { throw UpdateInstaller.InstallerError.invalidSignature }
        }
        XCTAssertThrowsError(try installer.prepare(newApp: new, currentApp: current))
        XCTAssertEqual(try readApp(current), "old")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), ["Current.app", "New.app"])
    }

    func testUnsignedOrInvalidBundlesAreRejected() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try makeApp(root, "Current.app", contents: "old")
        let new = try makeApp(root, "New.app", contents: "new")
        XCTAssertThrowsError(try UpdateInstaller().prepare(newApp: new, currentApp: current))
        XCTAssertEqual(try readApp(current), "old")
    }

    func testHelperRollsBackWhenOpeningReplacementFails() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try makeApp(root, "Current.app", contents: "old")
        let new = try makeApp(root, "New.app", contents: "new")
        let prepared = try UpdateInstaller(validate: { _, _ in }).prepare(newApp: new, currentApp: current)
        XCTAssertNotEqual(try runHelper(root: root, current: current, prepared: prepared, opener: "/usr/bin/false"), 0)
        XCTAssertEqual(try readApp(current), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.backup.path))
    }

    func testHelperKeepsBackupAndTreatsSpecialPathCharactersLiterally() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try makeApp(root, "Current ' $() app.app", contents: "old")
        let new = try makeApp(root, "New.app", contents: "new")
        let prepared = try UpdateInstaller(validate: { _, _ in }).prepare(newApp: new, currentApp: current)
        XCTAssertEqual(try runHelper(root: root, current: current, prepared: prepared, opener: "/usr/bin/true"), 0)
        XCTAssertEqual(try readApp(current), "new")
        XCTAssertEqual(try readApp(prepared.backup), "old")
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeApp(_ root: URL, _ name: String, contents: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url.appendingPathComponent("payload"))
        return url
    }

    private func readApp(_ url: URL) throws -> String {
        try String(contentsOf: url.appendingPathComponent("payload"), encoding: .utf8)
    }

    private func runHelper(root: URL, current: URL, prepared: UpdateInstaller.PreparedUpdate, opener: String) throws -> Int32 {
        let downloads = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let script = downloads.appendingPathComponent("update.sh")
        try UpdateInstaller.replacementScript.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // An impossible macOS PID prevents the helper from waiting on any real process.
        process.arguments = [script.path, "2147483647", current.path, prepared.replacement.path,
                             prepared.backup.path, downloads.path, downloads.appendingPathComponent("ready").path, opener]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

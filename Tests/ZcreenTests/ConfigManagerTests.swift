import XCTest
@testable import Zcreen

final class ConfigManagerTests: XCTestCase {

    func testInvalidReloadKeepsLastValidConfiguration() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeConfig("""
        {"version":1,"screens":[{"alias":"main","nameContains":"Display"}],
         "rules":[{"app":{"bundleId":"com.test.app"},"targetScreen":"main"}]}
        """, to: directory)
        let manager = ConfigManager(configDirectory: directory)
        try writeConfig("{ invalid json }", to: directory)
        manager.reload()
        XCTAssertNotNil(manager.configIssue)
        XCTAssertEqual(manager.configuration.effectiveRules.first?.app.bundleId, "com.test.app")
        try writeConfig("""
        {"version":2,"rules":[{"app":{"bundleId":"com.other.app"},"targetScreen":"missing"}]}
        """, to: directory)
        manager.reload()
        XCTAssertEqual(manager.configuration.version, 1)
        XCTAssertEqual(manager.configuration.effectiveRules.first?.app.bundleId, "com.test.app")
    }

    func testBlankNameMatcherIsRejected() throws {
        let directory = tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try writeConfig("""
        {"version":1,"screens":[{"alias":"main","nameContains":"Display"}],
         "rules":[{"app":{"nameContains":"   "},"targetScreen":"main"}]}
        """, to: directory)
        let manager = ConfigManager(configDirectory: directory)
        XCTAssertNotNil(manager.configIssue)
        XCTAssertTrue(manager.configuration.effectiveRules.isEmpty)
    }

    func testConfigIssueIncludesFieldPathForMissingVersion() throws {
        let configDirectory = tempDirectory()
        try writeConfig(
            """
            {
                "screens": [{"alias": "main", "nameContains": "Built-in"}]
            }
            """,
            to: configDirectory
        )

        let manager = ConfigManager(loadFromDisk: true, configDirectory: configDirectory)

        XCTAssertEqual(manager.configIssue?.summary, "Missing required field")
        XCTAssertEqual(manager.configIssue?.fieldPath, "version")
        XCTAssertEqual(manager.configIssue?.suggestion, "Add the missing field to config.json.")
    }

    func testConfigIssueIncludesSuggestionForUnknownTargetScreen() throws {
        let configDirectory = tempDirectory()
        try writeConfig(
            """
            {
                "version": 1,
                "screens": [{"alias": "main", "nameContains": "Built-in"}],
                "rules": [{
                    "app": {"bundleId": "com.apple.Safari"},
                    "targetScreen": "external"
                }]
            }
            """,
            to: configDirectory
        )

        let manager = ConfigManager(loadFromDisk: true, configDirectory: configDirectory)

        XCTAssertEqual(manager.configIssue?.summary, "Unknown target screen alias 'external'")
        XCTAssertEqual(manager.configIssue?.fieldPath, "rules[0].targetScreen")
        XCTAssertEqual(manager.configIssue?.suggestion, "Add the alias to screens or change targetScreen to an existing alias.")
    }

    private func writeConfig(_ json: String, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(json.data(using: .utf8))
        try data.write(to: directory.appendingPathComponent("config.json"))
    }

    private func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

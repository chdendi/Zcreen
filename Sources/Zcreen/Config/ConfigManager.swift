import Foundation
import Cocoa
import Combine

struct ConfigIssue: Equatable {
    let summary: String
    let fieldPath: String?
    let suggestion: String

    var message: String {
        if let fieldPath, !fieldPath.isEmpty {
            return "\(summary) (\(fieldPath))"
        }
        return summary
    }
}

final class ConfigManager: ObservableObject {
    @Published private(set) var configuration: Configuration
    @Published private(set) var configIssue: ConfigIssue?

    private let configDir: URL
    private let configFileURL: URL
    private var fileMonitor: DispatchSourceFileSystemObject?

    var hasConfigFile: Bool {
        FileManager.default.fileExists(atPath: configFileURL.path)
    }

    var configError: String? {
        configIssue?.message
    }

    init(loadFromDisk: Bool = true, configDirectory: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        configDir = configDirectory ?? home.appendingPathComponent(".config/zcreen")
        configFileURL = configDir.appendingPathComponent("config.json")

        // Start with empty config (zero-config mode)
        configuration = Configuration.empty
        configIssue = nil

        // Ensure directory exists (needed for snapshots)
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)

        // Load config file if it exists (optional — app works without it)
        if loadFromDisk, FileManager.default.fileExists(atPath: configFileURL.path) {
            loadConfig()
            watchConfigFile()
        }
    }

    deinit {
        fileMonitor?.cancel()
    }

    func reload() {
        if FileManager.default.fileExists(atPath: configFileURL.path) {
            loadConfig()
            if fileMonitor == nil { watchConfigFile() }
        }
    }

    func createExampleConfig() {
        let example = Configuration(
            version: 1,
            debounceMs: 500,
            screens: [
                ScreenAlias(alias: "dell-portrait", nameContains: "U2723QE"),
                ScreenAlias(alias: "dell-main", nameContains: "UP2720Q"),
                ScreenAlias(alias: "macbook", nameContains: "Built-in"),
            ],
            rules: [
                Rule(app: AppMatcher(bundleId: "com.mitchellh.ghostty", nameContains: nil),
                     targetScreen: "dell-portrait", profileOverrides: nil),
                Rule(app: AppMatcher(bundleId: "com.google.Chrome", nameContains: nil),
                     targetScreen: "dell-main",
                     profileOverrides: ["2-screen": "macbook"]),
            ],
            profiles: [
                "3-screen": ProfileDef(screenCount: 3),
                "2-screen": ProfileDef(screenCount: 2),
            ],
            windowFilter: WindowFilterConfig(
                excludedApps: [AppMatcher(bundleId: "com.apple.finder", nameContains: nil)],
                excludedRoles: nil,
                excludedSubroles: ["AXFloatingWindow"],
                minWidth: 50,
                minHeight: 50,
                excludeMinimized: true
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            let data = try encoder.encode(example)
            try data.write(to: configFileURL)
            loadConfig()
            watchConfigFile()
            Log.config.info("Example config created at \(self.configFileURL.path)")
        } catch {
            Log.config.error("Failed to create example config: \(error.localizedDescription)")
        }
    }

    func openConfigInEditor() {
        if !hasConfigFile { createExampleConfig() }
        NSWorkspace.shared.open(configFileURL)
    }

    func openConfigDirectory() {
        try? FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: configDir.path)
    }

    func openSnapshotsDirectory() {
        let snapshotDir = configDir.appendingPathComponent("snapshots")
        try? FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: snapshotDir.path)
    }

    var configFilePath: String {
        configFileURL.path
    }

    func setStateForTesting(configuration: Configuration, error: String? = nil, issue: ConfigIssue? = nil) {
        self.configuration = configuration
        self.configIssue = issue ?? error.map {
            ConfigIssue(summary: $0, fieldPath: nil, suggestion: "Open config.json and correct the value.")
        }
    }

    // MARK: - Private

    private func loadConfig() {
        do {
            let data = try Data(contentsOf: configFileURL)
            let decoded = try JSONDecoder().decode(Configuration.self, from: data)

            // Validate schema
            if let issue = validate(decoded) {
                configIssue = issue
                Log.config.error("Config validation failed: \(issue.message)")
                // Keep the last known-good configuration while the user edits the file.
                return
            }

            configuration = decoded
            configIssue = nil
            Log.config.info("Config loaded: \(self.configuration.effectiveRules.count) rules")
        } catch let error as DecodingError {
            let issue = decodingIssue(for: error)
            configIssue = issue
            Log.config.error("Failed to parse config: \(issue.message)")
        } catch {
            configIssue = ConfigIssue(
                summary: "Cannot read config file",
                fieldPath: nil,
                suggestion: "Check that config.json exists and that Zcreen can read it."
            )
            Log.config.error("Failed to load config: \(error.localizedDescription)")
        }
    }

    /// Validate config schema, returns error details or nil if valid
    private func validate(_ config: Configuration) -> ConfigIssue? {
        // Check version
        if config.version != 1 {
            return ConfigIssue(
                summary: "Unsupported config version \(config.version)",
                fieldPath: "version",
                suggestion: "Set version to 1."
            )
        }

        // Check screen alias uniqueness
        if let screens = config.screens {
            if screens.contains(where: { $0.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                $0.nameContains.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return ConfigIssue(summary: "Screen alias and name matcher cannot be blank", fieldPath: "screens",
                                   suggestion: "Use a non-empty alias and display name matcher.")
            }
            let aliases = screens.map(\.alias)
            let unique = Set(aliases)
            if aliases.count != unique.count {
                let dupes = aliases.filter { a in aliases.filter { $0 == a }.count > 1 }
                return ConfigIssue(
                    summary: "Duplicate screen alias: \(Set(dupes).sorted().joined(separator: ", "))",
                    fieldPath: "screens[].alias",
                    suggestion: "Give each screen entry a unique alias."
                )
            }
        }

        // Check rules reference valid screen aliases
        if let rules = config.rules, !rules.isEmpty, config.screens == nil {
            return ConfigIssue(
                summary: "Rules are configured but no screens aliases exist",
                fieldPath: "screens",
                suggestion: "Add a screens section or remove the rules that reference targetScreen aliases."
            )
        }
        if let rules = config.rules, let screens = config.screens {
            let validAliases = Set(screens.map(\.alias))
            for (i, rule) in rules.enumerated() {
                if !validAliases.contains(rule.targetScreen) {
                    return ConfigIssue(
                        summary: "Unknown target screen alias '\(rule.targetScreen)'",
                        fieldPath: "rules[\(i)].targetScreen",
                        suggestion: "Add the alias to screens or change targetScreen to an existing alias."
                    )
                }
                if let overrides = rule.profileOverrides {
                    for (profile, alias) in overrides {
                        if !validAliases.contains(alias) {
                            return ConfigIssue(
                                summary: "Unknown profile override alias '\(alias)'",
                                fieldPath: "rules[\(i)].profileOverrides.\(profile)",
                                suggestion: "Use a screens alias that exists in the screens section."
                            )
                        }
                    }
                }
            }
        }

        // Check rules have at least bundleId or nameContains
        if let rules = config.rules {
            for (i, rule) in rules.enumerated() {
                if !rule.app.isValid {
                    return ConfigIssue(
                        summary: "Rule matcher is missing both bundleId and nameContains",
                        fieldPath: "rules[\(i)].app",
                        suggestion: "Provide at least one matcher so Zcreen can identify the app."
                    )
                }
            }
        }

        if let filter = config.windowFilter {
            if let minWidth = filter.minWidth, minWidth < 0 {
                return ConfigIssue(
                    summary: "windowFilter minimum width cannot be negative",
                    fieldPath: "windowFilter.minWidth",
                    suggestion: "Use 0 or a positive number."
                )
            }
            if let minHeight = filter.minHeight, minHeight < 0 {
                return ConfigIssue(
                    summary: "windowFilter minimum height cannot be negative",
                    fieldPath: "windowFilter.minHeight",
                    suggestion: "Use 0 or a positive number."
                )
            }
            if let excludedApps = filter.excludedApps {
                for (i, matcher) in excludedApps.enumerated() {
                    if !matcher.isValid {
                        return ConfigIssue(
                            summary: "windowFilter exclusion matcher is incomplete",
                            fieldPath: "windowFilter.excludedApps[\(i)]",
                            suggestion: "Provide bundleId or nameContains so the exclusion can match an app."
                        )
                    }
                }
            }
        }

        return nil
    }

    private func decodingIssue(for error: DecodingError) -> ConfigIssue {
        switch error {
        case .keyNotFound(let key, let context):
            return ConfigIssue(
                summary: "Missing required field",
                fieldPath: formattedPath(context.codingPath, appending: key),
                suggestion: "Add the missing field to config.json."
            )
        case .typeMismatch(let type, let context):
            let path = formattedPath(context.codingPath)
            return ConfigIssue(
                summary: "Type mismatch, expected \(type)",
                fieldPath: path,
                suggestion: "Check the value type at this path and make sure it matches the schema."
            )
        case .valueNotFound(_, let context):
            let path = formattedPath(context.codingPath)
            return ConfigIssue(
                summary: "Null value is not allowed here",
                fieldPath: path,
                suggestion: "Replace null with a valid value or remove the field."
            )
        case .dataCorrupted(let context):
            return ConfigIssue(
                summary: "Invalid JSON syntax",
                fieldPath: formattedPath(context.codingPath),
                suggestion: "Fix the JSON formatting near the reported location and try again."
            )
        @unknown default:
            return ConfigIssue(
                summary: "Unable to parse config",
                fieldPath: nil,
                suggestion: "Check config.json for invalid fields or JSON syntax."
            )
        }
    }

    private func formattedPath(_ codingPath: [CodingKey], appending key: CodingKey? = nil) -> String? {
        let fullPath = key.map { codingPath + [$0] } ?? codingPath
        guard !fullPath.isEmpty else { return nil }

        var path = ""
        for component in fullPath {
            if let index = component.intValue {
                path += "[\(index)]"
            } else if path.isEmpty {
                path = component.stringValue
            } else {
                path += ".\(component.stringValue)"
            }
        }
        return path
    }

    private func watchConfigFile() {
        fileMonitor?.cancel()

        let fd = open(configFileURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .main
        )

        source.setEventHandler { [weak self] in
            Log.config.info("Config file changed, reloading...")
            DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Timing.configReloadDelay) {
                self?.loadConfig()
                // Re-register monitor to handle atomic writes (rename + create new file)
                self?.watchConfigFile()
            }
        }

        source.setCancelHandler { close(fd) }
        source.resume()
        fileMonitor = source
    }
}

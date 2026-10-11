import Foundation

struct FeedbackGesture {
    private var count = 0
    private var lastTap = Date.distantPast

    mutating func tap(at date: Date = Date()) -> Bool {
        if date.timeIntervalSince(lastTap) > 2 || date < lastTap { count = 0 }
        lastTap = date
        count += 1
        guard count == 5 else { return false }
        count = 0
        return true
    }
}

struct FeedbackReport {
    static let recipient = "hg.dendi@gmail.com"
    let directory: URL
    let archive: URL
    let subject: String
    let body: String
    let attachedLogCount: Int
}

struct FeedbackReportBuilder {
    let logsDirectory: URL
    let outputDirectory: URL
    let version: String
    let systemVersion: String
    var maximumLogBytes = 4 * 1024 * 1024

    func build(description: String, includeLogs: Bool, now: Date = Date()) throws -> FeedbackReport {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw FeedbackError.emptyDescription }
        let directory = outputDirectory.appendingPathComponent("Zcreen-feedback-\(UUID().uuidString)")
        let content = directory.appendingPathComponent("Feedback")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        do {
            let body = """
            Zcreen feedback
            Version: \(version)
            macOS: \(systemVersion)
            Created: \(ISO8601DateFormatter().string(from: now))

            Description:
            \(text)
            """
            try body.write(to: content.appendingPathComponent("feedback.txt"), atomically: true, encoding: .utf8)
            var count = 0
            var remaining = maximumLogBytes
            if includeLogs {
                let files = (try? FileManager.default.contentsOfDirectory(at: logsDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey])) ?? []
                let recent = try files.filter { file in
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey])
                    return values.isRegularFile == true && values.isSymbolicLink != true &&
                        file.lastPathComponent.range(of: "^zcreen-[0-9]{8}(\\.1)?\\.log$", options: .regularExpression) != nil &&
                        (values.contentModificationDate ?? .distantPast) >= now.addingTimeInterval(-2 * 86_400)
                }.sorted { $0.lastPathComponent > $1.lastPathComponent }
                for file in recent where remaining > 0 {
                    let handle = try FileHandle(forReadingFrom: file)
                    defer { try? handle.close() }
                    let size = try handle.seekToEnd()
                    let limit = min(UInt64(remaining), size)
                    try handle.seek(toOffset: size - limit)
                    let data = try handle.read(upToCount: Int(limit)) ?? Data()
                    try data.write(to: content.appendingPathComponent(file.lastPathComponent), options: .atomic)
                    remaining -= data.count
                    count += 1
                }
            }
            let archive = directory.appendingPathComponent("Zcreen-feedback.zip")
            let zip = Process()
            zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            zip.arguments = ["-c", "-k", "--keepParent", content.path, archive.path]
            zip.standardOutput = FileHandle.nullDevice
            zip.standardError = FileHandle.nullDevice
            try zip.run()
            zip.waitUntilExit()
            guard zip.terminationStatus == 0 else { throw FeedbackError.archiveFailed }
            return FeedbackReport(directory: directory, archive: archive, subject: "Zcreen feedback (\(version))",
                                  body: body, attachedLogCount: count)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    enum FeedbackError: LocalizedError {
        case emptyDescription, archiveFailed
        var errorDescription: String? {
            switch self {
            case .emptyDescription: return "Describe the problem before creating a feedback draft."
            case .archiveFailed: return "Could not package the logs. Please retry."
            }
        }
    }
}

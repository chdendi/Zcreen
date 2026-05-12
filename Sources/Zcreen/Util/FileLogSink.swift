import Foundation

/// 本地滚动日志：写入 `~/Library/Logs/Zcreen/zcreen-YYYYMMDD.log`。
/// 启动时清理超过 retentionDays 的旧文件。线程安全（单 serial queue 串行追加）。
final class FileLogSink {
    static let shared = FileLogSink()

    /// 保留几天的日志（含今天）。1d 活跃 = 今天 + 昨天，便于跨日复盘。
    private let retentionDays = 2
    /// 单文件最大字节数，避免长时间运行单天日志撑爆。超过后追加内容轮转到 `.1` 后缀。
    private let maxFileBytes: Int = 10 * 1024 * 1024  // 10 MB

    private let queue = DispatchQueue(label: "com.zcreen.filelogsink", qos: .utility)
    private let dateFormatter: DateFormatter
    private let dayFormatter: DateFormatter
    private let logsDirectory: URL

    private var currentDayKey: String = ""
    private var currentFileURL: URL?
    private var currentHandle: FileHandle?

    private init() {
        let fm = FileManager.default
        let baseLogs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Zcreen", isDirectory: true)
            ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("Zcreen-Logs")
        logsDirectory = baseLogs
        try? fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyyMMdd"
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
    }

    /// 必须在 app 启动尽早调用一次，做清理 + 写入启动分隔符。
    func bootstrap() {
        queue.async { [weak self] in
            self?.cleanupOldFiles()
            self?.writeLine("---- Zcreen launched at \(Date()) ----")
        }
    }

    var directoryURL: URL { logsDirectory }

    func append(level: String, category: String, message: String) {
        let now = Date()
        let timestamp = dateFormatter.string(from: now)
        let line = "\(timestamp) [\(level)] [\(category)] \(message)\n"
        queue.async { [weak self] in
            self?.writeRaw(line, at: now)
        }
    }

    private func writeLine(_ message: String) {
        let line = "\(dateFormatter.string(from: Date())) \(message)\n"
        writeRaw(line, at: Date())
    }

    private func writeRaw(_ line: String, at date: Date) {
        let dayKey = dayFormatter.string(from: date)
        if dayKey != currentDayKey || currentHandle == nil {
            rotateTo(dayKey: dayKey)
            cleanupOldFiles()
        }
        guard let handle = currentHandle, let data = line.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            // 写失败时一次性重开 handle 兜底
            currentHandle = nil
        }
        if let url = currentFileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int, size > maxFileBytes {
            rolloverOversizedFile()
        }
    }

    private func rotateTo(dayKey: String) {
        currentHandle?.closeFile()
        currentHandle = nil
        let url = logsDirectory.appendingPathComponent("zcreen-\(dayKey).log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            currentHandle = handle
            currentFileURL = url
            currentDayKey = dayKey
        }
    }

    private func rolloverOversizedFile() {
        guard let url = currentFileURL else { return }
        currentHandle?.closeFile()
        currentHandle = nil
        let archived = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: archived)
        try? FileManager.default.moveItem(at: url, to: archived)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: url) {
            currentHandle = handle
        }
    }

    private func cleanupOldFiles() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: logsDirectory,
                                                       includingPropertiesForKeys: [.contentModificationDateKey],
                                                       options: [.skipsHiddenFiles])
        else { return }
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86_400)
        for url in entries where url.pathExtension == "log" {
            guard let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  mod < cutoff
            else { continue }
            try? fm.removeItem(at: url)
        }
    }
}

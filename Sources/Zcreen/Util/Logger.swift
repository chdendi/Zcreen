import os

/// 同时写入 unified logging (os.Logger) 和本地滚动文件 (FileLogSink)。
/// 调用方写法保持兼容：`Log.window.info("...")` / `.warning(...)` / `.error(...)`。
struct AppLogger {
    let category: String
    let osLog: os.Logger

    init(subsystem: String, category: String) {
        self.category = category
        self.osLog = os.Logger(subsystem: subsystem, category: category)
    }

    func debug(_ message: @autoclosure () -> String) {
        let m = message()
        osLog.debug("\(m, privacy: .public)")
        FileLogSink.shared.append(level: "DEBUG", category: category, message: m)
    }

    func info(_ message: @autoclosure () -> String) {
        let m = message()
        osLog.info("\(m, privacy: .public)")
        FileLogSink.shared.append(level: "INFO", category: category, message: m)
    }

    func notice(_ message: @autoclosure () -> String) {
        let m = message()
        osLog.notice("\(m, privacy: .public)")
        FileLogSink.shared.append(level: "NOTICE", category: category, message: m)
    }

    func warning(_ message: @autoclosure () -> String) {
        let m = message()
        osLog.warning("\(m, privacy: .public)")
        FileLogSink.shared.append(level: "WARN", category: category, message: m)
    }

    func error(_ message: @autoclosure () -> String) {
        let m = message()
        osLog.error("\(m, privacy: .public)")
        FileLogSink.shared.append(level: "ERROR", category: category, message: m)
    }

    func critical(_ message: @autoclosure () -> String) {
        let m = message()
        osLog.critical("\(m, privacy: .public)")
        FileLogSink.shared.append(level: "CRIT", category: category, message: m)
    }
}

enum Log {
    private static let subsystem = "com.zcreen.app"

    static let general = AppLogger(subsystem: subsystem, category: "general")
    static let screen = AppLogger(subsystem: subsystem, category: "screen")
    static let window = AppLogger(subsystem: subsystem, category: "window")
    static let config = AppLogger(subsystem: subsystem, category: "config")
    static let rule = AppLogger(subsystem: subsystem, category: "rule")
    static let snapshot = AppLogger(subsystem: subsystem, category: "snapshot")
}

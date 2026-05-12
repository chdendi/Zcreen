import SwiftUI

@main
struct ZcreenApp: App {
    @StateObject private var orchestrator = Orchestrator()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(orchestrator: orchestrator)
        } label: {
            Image(systemName: "rectangle.3.group")
        }
        .menuBarExtraStyle(.window)
    }

    init() {
        // 启动本地日志（清理 >2 天的旧文件 + 写启动分隔符），早于其它日志调用
        FileLogSink.shared.bootstrap()

        // Prompt for accessibility permission on first launch
        if !AccessibilityHelper.isTrusted {
            AccessibilityHelper.requestAccess()
        }
    }
}

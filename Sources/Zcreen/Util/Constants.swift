import Foundation
import CoreGraphics

enum Constants {
    enum SnapBar {
        /// 高频轮询间隔 (~60 Hz, 用于拖拽中)
        static let highFrequencyInterval: TimeInterval = 0.016
        /// 低频轮询间隔 (~30 Hz, 用于 idle 检测，确保 mouseDown 边沿低延迟)
        static let lowFrequencyInterval: TimeInterval = 0.033
        /// 触发拖拽的最小移动距离 (pt)
        static let dragThreshold: CGFloat = 12
        /// Title bar 检测高度 (pt)
        static let titleBarHeight: CGFloat = 50
        /// Title bar 点击检测扩展边距 (pt)
        static let titleBarPadding: CGFloat = 5
        /// Snap 后保存延迟 (s)
        static let snapSaveDelay: TimeInterval = 0.3
        /// Tracking 超时 tick 数 (高频 60Hz × 60 ≈ 1s，与原 4Hz × 5 等效)
        static let trackingTimeoutTicks: Int = 60
    }

    enum Layout {
        /// 分屏窗口间的间距 (pt)
        static let windowGap: CGFloat = 6
    }

    enum Panel {
        /// SnapBar 面板水平内边距 (pt)
        static let horizontalPadding: CGFloat = 22
        /// SnapBar 面板垂直内边距 (pt)
        static let verticalPadding: CGFloat = 18
        /// Preset 组之间的间距 (pt)
        static let groupGap: CGFloat = 22
        /// Label 高度 (pt)
        static let labelHeight: CGFloat = 18
        /// Icon 与 Label 之间的间距 (pt)
        static let iconLabelGap: CGFloat = 6
    }

    enum Timing {
        /// 屏幕变化 throttle 间隔 (ms)，begin/settle 状态机后 latest-event 触发延迟。
        static let screenChangeDebounceMs: Int = 100
        /// 系统从 sleep / lock 唤醒后等待"期望 profile"重新出现的 debounce 超时 (s)。
        /// 唤醒时 macOS 会按显示器逐块发送 reconfig 事件（在多屏 + 外接屏环境中
        /// 间隔可达数秒），自适应状态机用 expectedProfileKey 启发匹配 + 这个 timeout
        /// 兜底；只要在 timeout 内匹配到 expected profile 就立即 restore。
        static let wakeSettleDelay: TimeInterval = 8.0
        /// 第一次 restore 后再要求 N 秒静默才退出 wake-settle 窗口 (s)。
        /// cooldown 期内的 reconfig 事件被吸收（不再 restore），只有 profile 漂回
        /// expected 才会再次 restore。避免 macOS 反复抖动外接屏 mode 时窗口连跳。
        static let wakeSettleCooldownDelay: TimeInterval = 4.0
        /// 定时自动保存布局间隔 (s)
        static let layoutAutoSaveInterval: TimeInterval = 15
        /// 屏幕变化后延迟保存当前布局 (s) — 给用户更长的手动调整窗口期。
        static let screenChangeAutoSaveDelay: TimeInterval = 5.0
        /// 配置文件变化重载延迟 (s)
        static let configReloadDelay: TimeInterval = 0.2
        /// 快照恢复重试基础延迟 (s)
        static let snapshotRetryBaseDelay: TimeInterval = 0.4
        /// 快照恢复最大重试次数
        static let snapshotMaxRetries: Int = 3
        /// App 启动后轮询窗口间隔 (s)
        static let appLaunchPollInterval: TimeInterval = 0.5
        /// App 启动后轮询窗口最大次数
        static let appLaunchPollMaxAttempts: Int = 10
        /// App 启动规则执行后延迟保存布局 (s)
        static let appLaunchAutoSaveDelay: TimeInterval = 2.0
    }

    enum WindowFilter {
        /// 默认窗口最小宽度 (pt)
        static let minimumWidth: CGFloat = 50
        /// 默认窗口最小高度 (pt)
        static let minimumHeight: CGFloat = 50
    }
}

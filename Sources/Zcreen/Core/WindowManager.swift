import Cocoa
import ApplicationServices

class WindowManager {
    private let screenFramesProvider: () -> [CGRect]
    /// Apps whose AX calls recently timed out, skipped until the stored date so one hung
    /// app does not stall every enumeration on the main thread.
    private var unresponsiveUntil: [pid_t: Date] = [:]

    init(screenFramesProvider: @escaping () -> [CGRect] = { NSScreen.screens.map(\.frame) }) {
        self.screenFramesProvider = screenFramesProvider
    }

    struct WindowInfo {
        let pid: pid_t
        let bundleId: String?
        let appName: String
        let title: String?
        let role: String?
        let subrole: String?
        let isMinimized: Bool
        let frame: CGRect
        let axWindow: AXUIElement
    }

    func getAllWindows() -> [WindowInfo] {
        guard AccessibilityHelper.isTrusted else {
            Log.window.warning("Accessibility not trusted, cannot enumerate windows")
            return []
        }
        return enumerateWindows { _ in true }
    }

    /// Windows of the given apps only (an empty bundle ID stands for apps without one).
    /// Restore paths use this so apps absent from the snapshot are never queried.
    func getWindows(bundleIds: Set<String>) -> [WindowInfo] {
        guard !bundleIds.isEmpty, AccessibilityHelper.isTrusted else { return [] }
        return enumerateWindows { bundleIds.contains($0.bundleIdentifier ?? "") }
    }

    private func enumerateWindows(including include: (NSRunningApplication) -> Bool) -> [WindowInfo] {
        var result: [WindowInfo] = []
        let now = Date()
        unresponsiveUntil = unresponsiveUntil.filter { $0.value > now }

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && include(app) {
            let pid = app.processIdentifier
            guard unresponsiveUntil[pid] == nil else { continue }
            let bundleId = app.bundleIdentifier
            let appName = app.localizedName ?? "Unknown"

            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, Constants.Accessibility.messagingTimeout)
            var windowsRef: CFTypeRef?
            let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            if err == .cannotComplete {
                markUnresponsive(pid: pid, appName: appName)
                continue
            }
            guard err == .success, let windows = windowsRef as? [AXUIElement] else { continue }

            for window in windows {
                // The timeout is stored on this element, so later moves of the window inherit it.
                AXUIElementSetMessagingTimeout(window, Constants.Accessibility.messagingTimeout)
                let (frame, frameError) = readWindowFrame(window)
                if frameError == .cannotComplete {
                    markUnresponsive(pid: pid, appName: appName)
                    break
                }
                guard let frame else { continue }
                let title = getWindowTitle(window)
                let role = getStringAttribute(window, attribute: kAXRoleAttribute as CFString)
                let subrole = getStringAttribute(window, attribute: kAXSubroleAttribute as CFString)
                let isMinimized = getBoolAttribute(window, attribute: kAXMinimizedAttribute as CFString) ?? false
                result.append(WindowInfo(
                    pid: pid,
                    bundleId: bundleId,
                    appName: appName,
                    title: title,
                    role: role,
                    subrole: subrole,
                    isMinimized: isMinimized,
                    frame: frame,
                    axWindow: window
                ))
            }
        }

        return result
    }

    private func markUnresponsive(pid: pid_t, appName: String) {
        unresponsiveUntil[pid] = Date().addingTimeInterval(Constants.Accessibility.unresponsiveBackoff)
        Log.window.warning(
            "AX timed out for \(appName) (pid \(pid)); skipping it for \(Int(Constants.Accessibility.unresponsiveBackoff))s"
        )
    }

    /// Current frame of a window in Accessibility coordinates, or nil when it cannot be read.
    func frame(of window: AXUIElement) -> CGRect? {
        readWindowFrame(window).frame
    }

    func getWindows(bundleId: String) -> [WindowInfo] {
        guard AccessibilityHelper.isTrusted else { return [] }
        return enumerateWindows { $0.bundleIdentifier == bundleId }
    }

    func getAllWindows(filter: WindowFilter) -> [WindowInfo] {
        getAllWindows().filter(filter.allows(window:))
    }

    func getWindows(bundleIds: Set<String>, filter: WindowFilter) -> [WindowInfo] {
        getWindows(bundleIds: bundleIds).filter(filter.allows(window:))
    }

    func getWindows(bundleId: String, filter: WindowFilter) -> [WindowInfo] {
        getWindows(bundleId: bundleId).filter(filter.allows(window:))
    }

    @discardableResult
    func moveWindow(_ window: AXUIElement, to point: CGPoint) -> AXError {
        var position = point
        let positionValue = AXValueCreate(.cgPoint, &position)!
        let err = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        if err != .success {
            Log.window.warning("AX setPosition(\(point.x), \(point.y)) failed: \(err.rawValue)")
        }
        return err
    }

    @discardableResult
    func resizeWindow(_ window: AXUIElement, to size: CGSize) -> AXError {
        var sz = size
        let sizeValue = AXValueCreate(.cgSize, &sz)!
        let err = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        if err != .success {
            Log.window.warning("AX setSize(\(size.width), \(size.height)) failed: \(err.rawValue)")
        }
        return err
    }

    /// 恢复与规则路径使用的入口；测试替身覆盖这个方法记录移动。
    func moveWindow(_ window: AXUIElement, toFrame frame: CGRect) {
        moveWindow(window, toFrame: frame, constrainedTo: nil)
    }

    /// 多段式 set：size → position → size → position；末尾留 setPosition，避免某些 app
    /// 在收到 resize 通知后内部 layout 把 position attribute 又 reset 回去。
    /// 第一轮后如果实际 frame 偏差仍 >5pt，做一次反向兜底（position → size → position）。
    func moveWindow(_ window: AXUIElement, toFrame frame: CGRect, constrainedTo bounds: CGRect?) {
        let originalFrame = getWindowFrame(window)
        var aborted = false

        withEnhancedUserInterfaceDisabled(for: window) {
            // Pass 1: size-first，收尾 position。首个调用就超时说明 app 无响应，
            // 后续每次 set 都会再等一个超时，直接放弃这个窗口。
            if resizeWindow(window, to: frame.size) == .cannotComplete {
                Log.window.warning("moveWindow aborted [\(appDescription(for: window))]: app did not respond")
                aborted = true
                return
            }
            moveWindow(window, to: frame.origin)
            resizeWindow(window, to: frame.size)
            moveWindow(window, to: frame.origin)

            // 校验中间状态，如有明显偏差就以 position-first 的顺序再来一次
            if let mid = getWindowFrame(window) {
                let needsRetry = max(
                    abs(mid.origin.x - frame.origin.x),
                    abs(mid.origin.y - frame.origin.y),
                    abs(mid.width - frame.width),
                    abs(mid.height - frame.height)
                ) > 5
                if needsRetry {
                    moveWindow(window, to: frame.origin)
                    resizeWindow(window, to: frame.size)
                    moveWindow(window, to: frame.origin)
                }
            }

            // Grid 对齐 app（Ghostty / iTerm 等终端按字符尺寸对齐，部分 IDE 同理）
            // 会拒绝 setSize 到任意像素尺寸，size 改不动 → setPosition 的目标 y 又
            // 因实际 size 撑不下被边界 clamp，最后变成"贴边"而不是"居中"。
            // 兜底策略：如果实际 size 跟 target 差 >5pt，就用实际 size 尽量居中到
            // target frame；Snap Bar 传入屏幕可见区域时，避免 Xcode 这类最小尺寸较大的
            // 窗口为了居中而越出屏幕边缘。
            if let actual = getWindowFrame(window) {
                let sizeDiff = max(abs(actual.width - frame.width), abs(actual.height - frame.height))
                if sizeDiff > 5 {
                    let centeredOrigin = Self.fallbackOrigin(
                        actualSize: actual.size,
                        targetFrame: frame,
                        bounds: bounds
                    )
                    if abs(centeredOrigin.x - actual.origin.x) > 1 || abs(centeredOrigin.y - actual.origin.y) > 1 {
                        moveWindow(window, to: centeredOrigin)
                    }
                }
            }
        }

        // 最终校验，如果偏差仍 >10pt 记一条 warning 便于复盘
        if !aborted, let actual = getWindowFrame(window) {
            let dx = abs(actual.origin.x - frame.origin.x)
            let dy = abs(actual.origin.y - frame.origin.y)
            let dw = abs(actual.width - frame.width)
            let dh = abs(actual.height - frame.height)
            if max(dx, dy, dw, dh) > 10 {
                let from = originalFrame.map { "(\($0.origin.x), \($0.origin.y), \($0.width), \($0.height))" } ?? "?"
                let appLabel = appDescription(for: window)
                Log.window.warning(
                    "moveWindow drift [\(appLabel)]: "
                    + "from \(from) "
                    + "target (\(frame.origin.x), \(frame.origin.y), \(frame.width), \(frame.height)) "
                    + "actual (\(actual.origin.x), \(actual.origin.y), \(actual.width), \(actual.height)) "
                    + "drift dx=\(dx) dy=\(dy) dw=\(dw) dh=\(dh)"
                )
            }
        }
    }

    static func fallbackOrigin(actualSize: CGSize, targetFrame: CGRect, bounds: CGRect?) -> CGPoint {
        let centered = CGPoint(
            x: targetFrame.midX - actualSize.width / 2,
            y: targetFrame.midY - actualSize.height / 2
        )
        guard let bounds else { return centered }
        return CGPoint(
            x: clampedOrigin(centered.x, length: actualSize.width, lowerBound: bounds.minX, upperBound: bounds.maxX),
            y: clampedOrigin(centered.y, length: actualSize.height, lowerBound: bounds.minY, upperBound: bounds.maxY)
        )
    }

    private static func clampedOrigin(
        _ origin: CGFloat,
        length: CGFloat,
        lowerBound: CGFloat,
        upperBound: CGFloat
    ) -> CGFloat {
        let maxOrigin = upperBound - length
        guard maxOrigin > lowerBound else { return lowerBound }
        return Swift.min(Swift.max(origin, lowerBound), maxOrigin)
    }

    /// 一些 app（Office、部分自渲染 app、终端等）会注入 enhanced UI 包装层，
    /// 拦截 / 改写 setSize/setPosition。临时把 app 的 AXEnhancedUserInterface 设为 false
    /// 可绕过包装层。Rectangle / yabai / Magnet 等通用做法。
    /// 私有 attribute 名 "AXEnhancedUserInterface"。无副作用：操作完恢复原值。
    private func withEnhancedUserInterfaceDisabled(for window: AXUIElement, _ work: () -> Void) {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard pid > 0 else { work(); return }
        let app = AXUIElementCreateApplication(pid)
        let attr = "AXEnhancedUserInterface" as CFString

        var originalRef: CFTypeRef?
        let readErr = AXUIElementCopyAttributeValue(app, attr, &originalRef)
        let wasEnabled: Bool
        if readErr == .success,
           let cf = originalRef,
           CFGetTypeID(cf) == CFBooleanGetTypeID() {
            wasEnabled = CFBooleanGetValue((cf as! CFBoolean))
        } else {
            wasEnabled = false
        }

        if wasEnabled {
            AXUIElementSetAttributeValue(app, attr, kCFBooleanFalse)
        }
        work()
        if wasEnabled {
            AXUIElementSetAttributeValue(app, attr, kCFBooleanTrue)
        }
    }

    /// 取一段简洁的 app + 标题描述用于日志，便于定位是哪个 app 在抗拒 set frame。
    private func appDescription(for window: AXUIElement) -> String {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid=\(pid)"
        let title = getWindowTitle(window).map { String($0.prefix(40)) } ?? "?"
        return "\(appName) — \(title)"
    }

    func moveWindowToScreen(_ window: AXUIElement, currentFrame: CGRect, targetScreen: ScreenInfo) {
        let screenFrames = screenFramesProvider()
        guard let mainScreenFrame = CoordinateConverter.mainScreenFrame(from: screenFrames),
              let targetFrame = CoordinateConverter.accessibilityScreenFrame(for: targetScreen.frame, screenFrames: screenFrames)
        else {
            moveWindow(window, toFrame: currentFrame)
            return
        }

        let currentCenter = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        let sourceFrame = screenFrames.compactMap { screenFrame -> CGRect? in
            let accessibilityFrame = CoordinateConverter.nsToAccessibility(screenFrame, mainScreenFrame: mainScreenFrame)
            return accessibilityFrame.contains(currentCenter) ? accessibilityFrame : nil
        }.first ?? CoordinateConverter.nsToAccessibility(mainScreenFrame, mainScreenFrame: mainScreenFrame)

        // Calculate relative position (0..1)
        let relX = (currentFrame.origin.x - sourceFrame.origin.x) / sourceFrame.width
        let relY = (currentFrame.origin.y - sourceFrame.origin.y) / sourceFrame.height
        let relW = currentFrame.width / sourceFrame.width
        let relH = currentFrame.height / sourceFrame.height

        // Map to target screen
        let newX = targetFrame.origin.x + relX * targetFrame.width
        let newY = targetFrame.origin.y + relY * targetFrame.height
        let newW = min(relW * targetFrame.width, targetFrame.width)
        let newH = min(relH * targetFrame.height, targetFrame.height)

        let newFrame = CGRect(x: newX, y: newY, width: newW, height: newH)
        moveWindow(window, toFrame: newFrame)
        Log.window.info("Moved window to screen \(targetScreen.name) at \(newFrame.debugDescription)")
    }

    // MARK: - Private

    private func getWindowFrame(_ window: AXUIElement) -> CGRect? {
        readWindowFrame(window).frame
    }

    private func readWindowFrame(_ window: AXUIElement) -> (frame: CGRect?, error: AXError) {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?

        let positionError = AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef)
        guard positionError == .success else { return (nil, positionError) }
        let sizeError = AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        guard sizeError == .success,
              let positionValue = positionRef, CFGetTypeID(positionValue) == AXValueGetTypeID(),
              let sizeValue = sizeRef, CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return (nil, sizeError) }

        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return (CGRect(origin: position, size: size), .success)
    }

    private func getWindowTitle(_ window: AXUIElement) -> String? {
        getStringAttribute(window, attribute: kAXTitleAttribute as CFString)
    }

    private func getStringAttribute(_ window: AXUIElement, attribute: CFString) -> String? {
        var titleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &titleRef) == .success else {
            return nil
        }
        return titleRef as? String
    }

    private func getBoolAttribute(_ window: AXUIElement, attribute: CFString) -> Bool? {
        var valueRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute, &valueRef) == .success else {
            return nil
        }
        return valueRef as? Bool
    }
}

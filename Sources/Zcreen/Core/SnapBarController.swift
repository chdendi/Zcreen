import Cocoa
import ApplicationServices

final class SnapBarController: ObservableObject {
    @Published var isEnabled = true

    /// Called after a preset is applied, so the layout can be saved
    var onSnap: (() -> Void)?

    private let windowManager: WindowManager
    private var panel: SnapBarPanel?
    private var isShowing = false
    private var targetWindow: AXUIElement?
    private var targetScreen: NSScreen?

    private var pollTimer: Timer?
    private var isHighFrequency = false

    private enum DragState { case idle, tracking, snapping }
    private var dragState: DragState = .idle
    private var tickCount = 0
    private var initialMousePos: NSPoint?
    private var clickedTitleBar = false
    private var wasMouseDown = false

    init(windowManager: WindowManager, shouldStartPolling: Bool = true) {
        self.windowManager = windowManager
        if shouldStartPolling {
            startPolling(highFrequency: false)
        }
    }

    deinit { pollTimer?.invalidate() }

    // MARK: - Adaptive Polling (~30 Hz idle, ~60 Hz during drag)

    private func startPolling(highFrequency: Bool) {
        pollTimer?.invalidate()
        isHighFrequency = highFrequency
        let interval = highFrequency
            ? Constants.SnapBar.highFrequencyInterval
            : Constants.SnapBar.lowFrequencyInterval
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func switchToHighFrequency() {
        guard !isHighFrequency else { return }
        startPolling(highFrequency: true)
    }

    private func switchToLowFrequency() {
        guard isHighFrequency else { return }
        startPolling(highFrequency: false)
    }

    private func tick() {
        guard isEnabled else { return }
        guard AccessibilityHelper.isTrusted else {
            tickCount += 1
            if tickCount % 20 == 0 {
                Log.general.warning("Snap Bar: accessibility NOT trusted, tick \(self.tickCount)")
            }
            return
        }

        let mouseDown = (NSEvent.pressedMouseButtons & 1) != 0
        let mouse = NSEvent.mouseLocation

        if mouseDown && !wasMouseDown {
            onMouseDown(mouse)
        } else if mouseDown && wasMouseDown {
            onDragTick(mouse)
        } else if !mouseDown && wasMouseDown {
            onMouseUp(mouse)
        }

        wasMouseDown = mouseDown
    }

    // MARK: - Mouse Down: resolve the window under the mouse

    private func onMouseDown(_ mouse: NSPoint) {
        // 无论是否立刻解析到目标都进入 tracking：点击背景窗口时 app 激活与 AX
        // 焦点更新是异步的，mouseDown 边沿这一个 tick 上经常解析失败或解析到
        // 旧窗口；tracking 期间会周期性重试，直到命中标题栏或超时。
        switchToHighFrequency()
        dragState = .tracking
        tickCount = 0
        initialMousePos = mouse
        targetWindow = nil
        clickedTitleBar = false
        applyResolvedTarget(resolveDragTarget(at: mouse))
    }

    // MARK: - Drag tick: detect significant mouse movement from title bar

    private func onDragTick(_ mouse: NSPoint) {
        switch dragState {
        case .idle:
            return

        case .tracking:
            tickCount += 1

            if !clickedTitleBar {
                // 目标未命中标题栏：周期性重试解析，等待 app 激活 / AX 状态落定。
                // 一旦命中就锁定目标，不再重新解析。
                if tickCount % Constants.SnapBar.targetResolveRetryTicks == 0 {
                    applyResolvedTarget(resolveDragTarget(at: mouse))
                }
                if !clickedTitleBar {
                    if tickCount >= Constants.SnapBar.trackingTimeoutTicks {
                        dragState = .idle
                        switchToLowFrequency()
                    }
                    return
                }
            }

            guard let initial = initialMousePos else { return }
            let moved = hypot(mouse.x - initial.x, mouse.y - initial.y)
            if moved > Constants.SnapBar.dragThreshold {
                dragState = .snapping
                let screen = screenAt(mouse) ?? NSScreen.main!
                showPanel(on: screen)
                updateHighlight(at: mouse)
            }

        case .snapping:
            updateHighlight(at: mouse)

            if let cur = targetScreen,
               let next = screenAt(mouse),
               next != cur {
                showPanel(on: next)
            }

        }
    }

    // MARK: - Drag target resolution

    private struct DragTarget {
        let window: AXUIElement
        let inTitleBar: Bool
    }

    private func applyResolvedTarget(_ target: DragTarget?) {
        guard let target else { return }
        targetWindow = target.window
        clickedTitleBar = target.inTitleBar
    }

    /// 用系统级 AX hit-test 找鼠标正下方的窗口。旧实现用 frontmostApplication +
    /// focusedWindow 推断，只在"拖当前激活 app 的聚焦窗口"时正确——点击背景窗口
    /// 标题栏直接拖动时会解析到错误窗口，导致整个拖拽期间面板不出现。
    private func resolveDragTarget(at mouse: NSPoint) -> DragTarget? {
        guard let mainScreenFrame = CoordinateConverter.mainScreenFrame(from: NSScreen.screens.map(\.frame)) else { return nil }
        let mouseAX = CoordinateConverter.nsToAccessibility(mouse, mainScreenFrame: mainScreenFrame)

        guard let win = windowAt(mouseAX) ?? frontmostFocusedWindow() else {
            Log.general.debug("Snap Bar: no window resolved at (\(mouseAX.x), \(mouseAX.y))")
            return nil
        }
        guard isSnappable(win), let wFrame = windowFrame(win) else { return nil }

        let pad = Constants.SnapBar.titleBarPadding
        let titleBar = CGRect(x: wFrame.origin.x - pad,
                              y: wFrame.origin.y - pad,
                              width: wFrame.width + pad * 2,
                              height: Constants.SnapBar.titleBarHeight)
        return DragTarget(window: win, inTitleBar: titleBar.contains(mouseAX))
    }

    /// 系统级 hit-test：取鼠标下的 AX 元素，再取其所属窗口（kAXWindowAttribute，
    /// 个别元素不带该属性时沿 parent 链向上找 AXWindow）。
    private func windowAt(_ pointAX: CGPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        // 目标 app 无响应时 AX 调用默认可阻塞数秒，而这里跑在主线程轮询里，
        // 必须限定超时避免拖死 UI。
        AXUIElementSetMessagingTimeout(systemWide, Constants.SnapBar.axMessagingTimeout)
        var elementRef: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(pointAX.x), Float(pointAX.y), &elementRef) == .success,
              let element = elementRef
        else { return nil }
        AXUIElementSetMessagingTimeout(element, Constants.SnapBar.axMessagingTimeout)

        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
           let window = windowRef, CFGetTypeID(window) == AXUIElementGetTypeID() {
            return (window as! AXUIElement)
        }

        var current = element
        for _ in 0..<10 {
            if stringAttribute(current, kAXRoleAttribute as CFString) == kAXWindowRole as String {
                return current
            }
            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parent = parentRef, CFGetTypeID(parent) == AXUIElementGetTypeID()
            else { return nil }
            current = (parent as! AXUIElement)
        }
        return nil
    }

    /// hit-test 失败时的兜底：沿用旧的 frontmost + focused 推断。
    private func frontmostFocusedWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.activationPolicy == .regular
        else { return nil }

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        return focusedWindow(of: appEl) ?? firstWindow(of: appEl)
    }

    /// 过滤不该被 snap 的窗口：自己的面板、非常规 app（Spotlight 等）、桌面 /
    /// sheet 等非标准窗口。subrole 读不到时放行，避免误杀不规范 app 的主窗口。
    private func isSnappable(_ win: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(win, &pid) == .success,
              pid != ProcessInfo.processInfo.processIdentifier
        else { return false }
        guard let app = NSRunningApplication(processIdentifier: pid),
              app.activationPolicy == .regular
        else { return false }

        if let subrole = stringAttribute(win, kAXSubroleAttribute as CFString) {
            return subrole == kAXStandardWindowSubrole as String
                || subrole == kAXDialogSubrole as String
        }
        return true
    }

    // MARK: - Mouse Up: apply preset if highlighted

    private func onMouseUp(_ mouse: NSPoint) {
        defer {
            dragState = .idle
            tickCount = 0
            initialMousePos = nil
            clickedTitleBar = false
            switchToLowFrequency()
        }

        guard dragState == .snapping, isShowing, let panel else { return }

        // 优先用拖拽中最后一次高亮的 preset：mouseUp 是轮询检测的，
        // 此刻读到的鼠标位置可能比真实释放时刻晚 0~16ms，
        // 用 highlightedPreset 才能保证"所见即所得"。
        // 兜底：如果上一帧还没命中过任何 zone，再用当前位置兜底命中一次。
        if let preset = panel.state.highlightedPreset ?? panel.presetAt(mouse) {
            applyPreset(preset)
        }
        hidePanel()
    }

    // MARK: - Panel management

    private func showPanel(on screen: NSScreen) {
        panel?.hide()
        let groups = PresetGroup.groups(for: screen)
        panel = SnapBarPanel(groups: groups)
        panel?.show(on: screen)
        targetScreen = screen
        isShowing = true
    }

    private func hidePanel() {
        panel?.hide()
        isShowing = false
        targetScreen = nil
    }

    private func updateHighlight(at mouse: NSPoint) {
        panel?.updateHighlight(at: mouse)
    }

    // MARK: - Apply preset

    private func applyPreset(_ preset: LayoutPreset) {
        guard let win = targetWindow, let screen = targetScreen else { return }
        guard let mainScreenFrame = CoordinateConverter.mainScreenFrame(from: NSScreen.screens.map(\.frame)) else { return }

        let accessibilityVisible = CoordinateConverter.nsToAccessibility(screen.visibleFrame, mainScreenFrame: mainScreenFrame)
        let frame = preset.frame(for: accessibilityVisible)
        Log.general.info(
            "Snap '\(preset.id)' on \(screen.localizedName) "
            + "target=(\(frame.origin.x), \(frame.origin.y), \(frame.width), \(frame.height))"
        )
        windowManager.moveWindow(win, toFrame: frame)

        DispatchQueue.main.asyncAfter(deadline: .now() + Constants.SnapBar.snapSaveDelay) { [weak self] in
            self?.onSnap?()
        }
    }

    // MARK: - AX helpers

    private func focusedWindow(of app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref) == .success
        else { return nil }
        return (ref as! AXUIElement)
    }

    private func firstWindow(of app: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let wins = ref as? [AXUIElement], let first = wins.first
        else { return nil }
        return first
    }

    private func windowFrame(_ win: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &ref) == .success else { return nil }
        return ref as? String
    }

    private func screenAt(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

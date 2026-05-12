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

    // MARK: - Mouse Down: check if click is in a window's title bar

    private func onMouseDown(_ mouse: NSPoint) {
        // 先做所有 "获取信息" 的 guard，全部成功后再修改状态。
        // 任何 guard fail 都不会留下副作用（dragState 仍为 .idle，仍处于低频轮询）。
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier,
              app.activationPolicy == .regular
        else { return }

        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        guard let win = focusedWindow(of: appEl) ?? firstWindow(of: appEl) else { return }
        guard let wFrame = windowFrame(win) else { return }
        guard let mainScreenFrame = CoordinateConverter.mainScreenFrame(from: NSScreen.screens.map(\.frame)) else { return }

        let mouseAX = CoordinateConverter.nsToAccessibility(mouse, mainScreenFrame: mainScreenFrame)
        let pad = Constants.SnapBar.titleBarPadding
        let titleBar = CGRect(x: wFrame.origin.x - pad,
                              y: wFrame.origin.y - pad,
                              width: wFrame.width + pad * 2,
                              height: Constants.SnapBar.titleBarHeight)

        // 进入 tracking 才切高频，避免没目标窗口也升频空转
        switchToHighFrequency()
        dragState = .tracking
        tickCount = 0
        initialMousePos = mouse
        targetWindow = win
        clickedTitleBar = titleBar.contains(mouseAX)
    }

    // MARK: - Drag tick: detect significant mouse movement from title bar

    private func onDragTick(_ mouse: NSPoint) {
        switch dragState {
        case .idle:
            return

        case .tracking:
            tickCount += 1

            guard clickedTitleBar, let initial = initialMousePos else {
                if tickCount >= Constants.SnapBar.trackingTimeoutTicks {
                    dragState = .idle
                    switchToLowFrequency()
                }
                return
            }

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

    private func screenAt(_ point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}

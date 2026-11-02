import Cocoa
import Combine
import CoreGraphics

final class ScreenDetector: ObservableObject {
    /// Display geometry as CoreGraphics reports it right now. Only fields that agree between
    /// CoreGraphics (top-left origin) and AppKit (bottom-left origin) are kept.
    struct DisplayGeometry: Hashable {
        let displayID: CGDirectDisplayID
        let x: Int
        let width: Int
        let height: Int

        init(displayID: CGDirectDisplayID, frame: CGRect) {
            self.displayID = displayID
            self.x = Int(frame.minX.rounded())
            self.width = Int(frame.width.rounded())
            self.height = Int(frame.height.rounded())
        }
    }

    @Published private(set) var screens: [ScreenInfo] = []
    @Published private(set) var profileKey: String = ""
    @Published private(set) var profileLabel: String = ""

    private let screenChangeSubject = PassthroughSubject<Bool, Never>()
    private let beginConfigSubject = PassthroughSubject<Void, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var callbackRegistered = false
    private var liveGeometryProvider: () -> Set<DisplayGeometry>

    var screenCount: Int { screens.count }

    /// Like `profileKey`, but also changes when a display's resolution, arrangement or
    /// main-display role changes. Same physical displays do not imply the same layout.
    var topologyFingerprint: String { Self.topologyFingerprint(of: screens) }

    static func topologyFingerprint(of screens: [ScreenInfo]) -> String {
        screens.map { screen in
            let frame = screen.frame
            return "\(screen.uniqueKey)@\(Int(frame.minX.rounded())),\(Int(frame.minY.rounded())),"
                + "\(Int(frame.width.rounded()))x\(Int(frame.height.rounded()))"
        }
        .sorted()
        .joined(separator: "|")
    }

    /// Whether WindowServer still reports the displays this detector last refreshed.
    /// `NSScreen` only updates once the run loop delivers the screen-change notification,
    /// so this asks CoreGraphics directly. Returns true when the live state is unavailable.
    func liveGeometryMatchesScreens() -> Bool {
        let live = liveGeometryProvider()
        guard !live.isEmpty else { return true }
        return live == Set(screens.map { DisplayGeometry(displayID: $0.displayID, frame: $0.frame) })
    }

    /// Fires after screen changes settle. Emits the new profileKey.
    /// Wait for a quiet interval, including begin pulses, before refreshing topology.
    var onScreensChanged: AnyPublisher<String, Never> {
        screenChangeSubject
            .debounce(for: .milliseconds(Constants.Timing.screenChangeDebounceMs), scheduler: DispatchQueue.main)
            .filter { $0 }
            .map { [weak self] _ in
                self?.refreshScreens()
                return self?.profileKey ?? ""
            }
            .eraseToAnyPublisher()
    }

    /// Fires immediately when macOS announces a display reconfiguration is about to begin.
    /// Use this to save a snapshot BEFORE screens change and macOS rearranges windows.
    var onBeginConfiguration: AnyPublisher<Void, Never> {
        beginConfigSubject.eraseToAnyPublisher()
    }

    init(shouldRegisterCallback: Bool = true,
         liveGeometryProvider: @escaping () -> Set<DisplayGeometry> = ScreenDetector.currentDisplayGeometry) {
        self.liveGeometryProvider = liveGeometryProvider
        refreshScreens()
        if shouldRegisterCallback {
            registerCallback()
        }
    }

    deinit {
        if callbackRegistered {
            CGDisplayRemoveReconfigurationCallback(displayReconfigCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    /// Screens as AppKit currently reports them, unsorted and without position labels.
    static func currentSystemScreens() -> [ScreenInfo] {
        NSScreen.screens.map { screen in
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return ScreenInfo(
                displayID: displayID,
                name: screen.localizedName,
                frame: screen.frame,
                isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
                position: .single,
                vendorID: CGDisplayVendorNumber(displayID),
                modelID: CGDisplayModelNumber(displayID),
                serialNumber: CGDisplaySerialNumber(displayID)
            )
        }
    }

    /// Active displays straight from WindowServer. Hardware mirrors are skipped because
    /// AppKit exposes only one screen per mirror set.
    static func currentDisplayGeometry() -> Set<DisplayGeometry> {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Set(ids.prefix(Int(count))
            .filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
            .map { DisplayGeometry(displayID: $0, frame: CGDisplayBounds($0)) })
    }

    @discardableResult
    func refreshScreens() -> String {
        var infos = Self.currentSystemScreens()
        infos.sort { $0.frame.origin.x < $1.frame.origin.x }
        screens = assignPositions(infos)
        profileKey = generateProfileKey(from: screens)
        profileLabel = generateProfileLabel(from: screens)
        Log.screen.info("Detected \(self.screens.count) screens, profile: \(self.profileLabel) [\(self.profileKey)]")
        return profileKey
    }

    func screenInfo(forAlias alias: String, configuration: Configuration) -> ScreenInfo? {
        guard let screenAlias = configuration.screens?.first(where: { $0.alias == alias }) else {
            return nil
        }
        return screens.first { $0.name.localizedCaseInsensitiveContains(screenAlias.nameContains) }
    }

    private func assignPositions(_ infos: [ScreenInfo]) -> [ScreenInfo] {
        guard infos.count > 1 else {
            return infos.map { rebuild($0, position: .single) }
        }

        return infos.enumerated().map { index, info in
            let position: ScreenPosition
            if index == 0 {
                position = .leftmost
            } else if index == infos.count - 1 {
                position = .rightmost
            } else {
                position = .center
            }
            return rebuild(info, position: position)
        }
    }

    private func rebuild(_ info: ScreenInfo, position: ScreenPosition) -> ScreenInfo {
        ScreenInfo(
            displayID: info.displayID,
            name: info.name,
            frame: info.frame,
            isBuiltIn: info.isBuiltIn,
            position: position,
            vendorID: info.vendorID,
            modelID: info.modelID,
            serialNumber: info.serialNumber,
            persistentID: info.persistentID
        )
    }

    /// Profile key = sorted persistent display UUIDs joined with "+".
    private func generateProfileKey(from screens: [ScreenInfo]) -> String {
        screens.map { $0.uniqueKey }.sorted().joined(separator: "+")
    }

    /// Human-readable label, e.g. "Built-in + U2723QE + UP2720Q"
    private func generateProfileLabel(from screens: [ScreenInfo]) -> String {
        screens.map { $0.shortName }.sorted().joined(separator: " + ")
    }

    private func registerCallback() {
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayReconfigCallback, pointer)
        callbackRegistered = true
    }

    func handleDisplayChange(flags: CGDisplayChangeSummaryFlags) {
        if flags.contains(.beginConfigurationFlag) {
            // Begin pulses reset the quiet interval without publishing a completion.
            beginConfigSubject.send()
            screenChangeSubject.send(false)
            return
        }

        // CoreGraphics invokes a post-configuration callback for every online
        // display. An unchanged display may have no flags; it still ends the
        // transaction. Mode, mirroring and desktop-shape changes also settle here.
        screenChangeSubject.send(true)
    }

    /// Replaces the detected state. Unless `liveGeometry` is given, WindowServer is assumed
    /// to report the same displays.
    func setStateForTesting(screens: [ScreenInfo], profileKey: String? = nil, profileLabel: String? = nil,
                            liveGeometry: Set<DisplayGeometry>? = nil) {
        let geometry = liveGeometry ?? Set(screens.map { DisplayGeometry(displayID: $0.displayID, frame: $0.frame) })
        liveGeometryProvider = { geometry }
        let sorted = screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
        self.screens = assignPositions(sorted)
        self.profileKey = profileKey ?? generateProfileKey(from: self.screens)
        self.profileLabel = profileLabel ?? generateProfileLabel(from: self.screens)
    }
}

private func displayReconfigCallback(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags, userInfo: UnsafeMutableRawPointer?) {
    guard let userInfo else { return }
    let detector = Unmanaged<ScreenDetector>.fromOpaque(userInfo).takeUnretainedValue()
    DispatchQueue.main.async {
        detector.handleDisplayChange(flags: flags)
    }
}

import Cocoa
import Combine
import CoreGraphics

final class ScreenDetector: ObservableObject {
    @Published private(set) var screens: [ScreenInfo] = []
    @Published private(set) var profileKey: String = ""
    @Published private(set) var profileLabel: String = ""

    private let screenChangeSubject = PassthroughSubject<Bool, Never>()
    private let beginConfigSubject = PassthroughSubject<Void, Never>()
    private var cancellables = Set<AnyCancellable>()
    private var callbackRegistered = false

    var screenCount: Int { screens.count }

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

    init(shouldRegisterCallback: Bool = true) {
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

    @discardableResult
    func refreshScreens() -> String {
        let nsScreens = NSScreen.screens
        var infos: [ScreenInfo] = []

        for screen in nsScreens {
            let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            let name = screen.localizedName
            let frame = screen.frame
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let vendorID = CGDisplayVendorNumber(displayID)
            let modelID = CGDisplayModelNumber(displayID)
            let serialNumber = CGDisplaySerialNumber(displayID)

            infos.append(ScreenInfo(
                displayID: displayID,
                name: name,
                frame: frame,
                isBuiltIn: isBuiltIn,
                position: .single,
                vendorID: vendorID,
                modelID: modelID,
                serialNumber: serialNumber
            ))
        }

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

    func setStateForTesting(screens: [ScreenInfo], profileKey: String? = nil, profileLabel: String? = nil) {
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

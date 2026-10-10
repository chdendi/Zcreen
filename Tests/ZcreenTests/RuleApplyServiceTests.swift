import XCTest
import ApplicationServices
@testable import Zcreen

final class RuleApplyServiceTests: XCTestCase {
    private let bundleId = "com.mitchellh.ghostty"
    private let portraitFrame = CGRect(x: -969, y: -858, width: 858, height: 1506)

    func testLaunchRestoresSavedPortraitLayoutInsteadOfScalingLandscapeWindow() throws {
        let fixture = makeFixture()
        save([savedWindow(frame: portraitFrame, screen: fixture.portrait, screens: fixture.screens)], in: fixture)
        fixture.manager.windows = [runningWindow(frame: CGRect(x: 0, y: -1078, width: 858, height: 1050))]

        launch(fixture)

        XCTAssertEqual(try XCTUnwrap(fixture.manager.moves.first).frame, portraitFrame)
        XCTAssertTrue(fixture.manager.fallbackMoves.isEmpty)
    }

    func testLaunchRestoresSizeEvenWhenWindowIsAlreadyOnTargetScreen() throws {
        let fixture = makeFixture()
        save([savedWindow(frame: portraitFrame, screen: fixture.portrait, screens: fixture.screens)], in: fixture)
        fixture.manager.windows = [runningWindow(frame: CGRect(x: -1080, y: -1000, width: 482.625, height: 1506))]

        launch(fixture)

        XCTAssertEqual(try XCTUnwrap(fixture.manager.moves.first).frame, portraitFrame)
        XCTAssertTrue(fixture.manager.fallbackMoves.isEmpty)
    }

    func testLaunchWithoutHistoryUsesExistingMoveToScreenFallback() {
        let fixture = makeFixture()
        fixture.manager.windows = [runningWindow()]

        launch(fixture)

        XCTAssertTrue(fixture.manager.moves.isEmpty)
        XCTAssertEqual(fixture.manager.fallbackMoves.count, 1)
        XCTAssertEqual(fixture.manager.fallbackMoves.first?.targetScreen.uniqueKey, fixture.portrait.uniqueKey)
    }

    func testHistoryFromAnotherScreenCombinationDoesNotOverrideCurrentLayout() {
        let fixture = makeFixture()
        save([savedWindow(frame: portraitFrame, screen: fixture.portrait, screens: fixture.screens)],
             in: fixture, profileKey: "another-profile")
        fixture.manager.windows = [runningWindow()]

        launch(fixture)

        XCTAssertTrue(fixture.manager.moves.isEmpty)
        XCTAssertEqual(fixture.manager.fallbackMoves.count, 1)
    }

    func testNoHistoryLeavesWindowAlreadyOnTargetAlone() {
        let fixture = makeFixture()
        fixture.manager.windows = [runningWindow(frame: portraitFrame)]

        launch(fixture)

        XCTAssertTrue(fixture.manager.moves.isEmpty)
        XCTAssertTrue(fixture.manager.fallbackMoves.isEmpty)
    }

    func testRuleOverridesSavedDisplayWhilePreservingSavedSize() throws {
        let fixture = makeFixture()
        let savedFrame = CGRect(x: 200, y: -1000, width: 858, height: 900)
        save([savedWindow(frame: savedFrame, screen: fixture.landscape, screens: fixture.screens)], in: fixture)
        fixture.manager.windows = [runningWindow()]

        _ = fixture.service.applyAllRules()

        let frame = try XCTUnwrap(fixture.manager.moves.first).frame
        XCTAssertEqual(frame.width, 858, accuracy: 0.001)
        XCTAssertEqual(frame.height, 900, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(CoordinateConverter.accessibilityScreenFrame(
            for: fixture.portrait, screens: fixture.screens
        )).contains(frame))
        XCTAssertTrue(fixture.manager.fallbackMoves.isEmpty)
    }

    func testOversizedSavedWindowFitsRuleTargetWithoutProportionalShrinking() throws {
        let fixture = makeFixture()
        save([savedWindow(frame: CGRect(x: 0, y: -1000, width: 1600, height: 900),
                          screen: fixture.landscape, screens: fixture.screens)], in: fixture)
        fixture.manager.windows = [runningWindow()]

        launch(fixture)

        let frame = try XCTUnwrap(fixture.manager.moves.first).frame
        XCTAssertEqual(frame.width, 1080, accuracy: 0.001)
        XCTAssertEqual(frame.height, 900, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(CoordinateConverter.accessibilityScreenFrame(
            for: fixture.portrait, screens: fixture.screens
        )).contains(frame))
    }

    func testLegacySnapshotWithoutRelativeGeometryStillRestoresSavedSize() throws {
        let fixture = makeFixture()
        let saved = WindowSnapshot(bundleId: bundleId, appName: "Ghostty", windowTitle: "Terminal",
                                   frame: .init(portraitFrame), screenName: "DELL U2723QE")
        save([saved], in: fixture)
        fixture.manager.windows = [runningWindow()]

        launch(fixture)

        XCTAssertEqual(try XCTUnwrap(fixture.manager.moves.first).frame, portraitFrame)
        XCTAssertTrue(fixture.manager.fallbackMoves.isEmpty)
    }

    func testMultipleWindowsMatchTheirOwnSavedTitlesAndExtraWindowUsesFallback() throws {
        let fixture = makeFixture()
        let smallFrame = CGRect(x: -1050, y: -1050, width: 600, height: 700)
        save([
            savedWindow(title: "Large", frame: portraitFrame, screen: fixture.portrait, screens: fixture.screens),
            savedWindow(title: "Small", frame: smallFrame, screen: fixture.portrait, screens: fixture.screens)
        ], in: fixture)
        let small = runningWindow(title: "Small", pid: 111)
        let large = runningWindow(title: "Large", pid: 112)
        let extra = runningWindow(title: "New", pid: 113)
        fixture.manager.windows = [small, large, extra]

        launch(fixture)

        XCTAssertEqual(fixture.manager.moves.count, 2)
        let smallMove = try XCTUnwrap(fixture.manager.moves.first { CFEqual($0.window, small.axWindow) })
        let largeMove = try XCTUnwrap(fixture.manager.moves.first { CFEqual($0.window, large.axWindow) })
        XCTAssertEqual(smallMove.frame, smallFrame)
        XCTAssertEqual(largeMove.frame, portraitFrame)
        XCTAssertEqual(fixture.manager.fallbackMoves.count, 1)
        XCTAssertTrue(CFEqual(try XCTUnwrap(fixture.manager.fallbackMoves.first).window, extra.axWindow))
    }

    func testExcludedSavedWindowDoesNotSupplyGeometry() {
        let fixture = makeFixture()
        let saved = WindowSnapshot(bundleId: bundleId, appName: "Ghostty", windowTitle: "Terminal",
                                   frame: .init(portraitFrame), screenName: "DELL U2723QE",
                                   windowRole: "AXWindow", windowSubrole: "AXFloatingWindow")
        save([saved], in: fixture)
        fixture.manager.windows = [runningWindow()]

        launch(fixture)

        XCTAssertTrue(fixture.manager.moves.isEmpty)
        XCTAssertEqual(fixture.manager.fallbackMoves.count, 1)
    }

    func testConfiguredRuleWindowIsSavedAndUpdatedThroughSnapshotService() throws {
        let fixture = makeFixture()
        let service = SnapshotService(screenSession: ScreenSessionService(screenDetector: fixture.detector),
                                      configManager: fixture.config, windowManager: fixture.manager,
                                      snapshotStore: fixture.store)
        fixture.manager.windows = [runningWindow(frame: portraitFrame)]
        _ = service.saveCurrentLayout(trigger: .snapBar, force: true)
        XCTAssertEqual(try XCTUnwrap(fixture.store.load(profileKey: "desk")?.windows.first).frame.cgRect, portraitFrame)

        let updatedFrame = CGRect(x: -1050, y: -900, width: 1000, height: 1400)
        fixture.manager.windows = [runningWindow(frame: updatedFrame)]
        _ = service.saveCurrentLayout(trigger: .periodic, force: false)
        fixture.manager.windows = [runningWindow()]

        launch(fixture)

        XCTAssertEqual(try XCTUnwrap(fixture.manager.moves.first).frame, updatedFrame)
    }

    func testManualRestoreUsesRuleTargetAndSavedGeometryOnce() throws {
        let fixture = makeFixture()
        let savedFrame = CGRect(x: 200, y: -1000, width: 858, height: 900)
        save([savedWindow(frame: savedFrame, screen: fixture.landscape, screens: fixture.screens)], in: fixture)
        fixture.manager.windows = [runningWindow()]
        let orchestrator = makeOrchestrator(fixture)

        orchestrator.restoreCurrentLayout()

        XCTAssertEqual(fixture.manager.moves.count, 1)
        let frame = try XCTUnwrap(fixture.manager.moves.first).frame
        XCTAssertEqual(frame.width, savedFrame.width, accuracy: 0.001)
        XCTAssertEqual(frame.height, savedFrame.height, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(CoordinateConverter.accessibilityScreenFrame(
            for: fixture.portrait, screens: fixture.screens
        )).contains(frame))
        XCTAssertTrue(fixture.manager.fallbackMoves.isEmpty)
        XCTAssertEqual(orchestrator.lastAction, "Restored layout for Desk")
    }

    func testUnavailableRuleTargetKeepsOrdinarySnapshotRestore() throws {
        let fixture = makeFixture()
        let savedFrame = CGRect(x: 200, y: -1000, width: 858, height: 900)
        save([savedWindow(frame: savedFrame, screen: fixture.landscape, screens: fixture.screens)], in: fixture)
        fixture.detector.setStateForTesting(
            screens: fixture.screens.filter { $0.uniqueKey != fixture.portrait.uniqueKey },
            profileKey: "desk", profileLabel: "Desk"
        )
        fixture.manager.windows = [runningWindow()]
        let orchestrator = makeOrchestrator(fixture)

        orchestrator.handleScreenChange(newProfileKey: "desk")

        XCTAssertEqual(fixture.manager.moves.count, 1)
        XCTAssertEqual(try XCTUnwrap(fixture.manager.moves.first).frame, savedFrame)
        XCTAssertTrue(fixture.manager.fallbackMoves.isEmpty)
    }

    func testLaunchWaitsForWindowAndThenRestoresHistory() throws {
        var pending: [() -> Void] = []
        let fixture = makeFixture(scheduleAfter: { _, action in pending.append(action) })
        save([savedWindow(frame: portraitFrame, screen: fixture.portrait, screens: fixture.screens)], in: fixture)
        var completed = false

        fixture.service.handleAppLaunch(bundleId: bundleId, appName: "Ghostty") { result in
            XCTAssertEqual(result?.targetScreenAlias, "portrait")
            completed = true
        }
        XCTAssertFalse(completed)
        XCTAssertEqual(pending.count, 1)
        fixture.manager.windows = [runningWindow()]
        pending.removeFirst()()

        XCTAssertTrue(completed)
        XCTAssertEqual(try XCTUnwrap(fixture.manager.moves.first).frame, portraitFrame)
        XCTAssertTrue(fixture.manager.fallbackMoves.isEmpty)
    }

    private struct Fixture {
        let service: RuleApplyService
        let detector: ScreenDetector
        let config: ConfigManager
        let store: LayoutSnapshotStore
        let manager: RuleTestWindowManager
        let portrait: ScreenInfo
        let landscape: ScreenInfo
        let screens: [ScreenInfo]
    }

    private func makeFixture(
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { _, _ in }
    ) -> Fixture {
        let builtIn = screen(id: 901, name: "Built-in Retina Display",
                             frame: CGRect(x: 0, y: 0, width: 1512, height: 982))
        let portrait = screen(id: 902, name: "DELL U2723QE",
                              frame: CGRect(x: -1080, y: 142, width: 1080, height: 1920))
        let landscape = screen(id: 903, name: "DELL UP2720Q",
                               frame: CGRect(x: 0, y: 982, width: 1920, height: 1080))
        let screens = [builtIn, portrait, landscape]
        let detector = ScreenDetector(shouldRegisterCallback: false)
        detector.setStateForTesting(screens: screens, profileKey: "desk", profileLabel: "Desk")
        let config = ConfigManager(loadFromDisk: false, configDirectory: temporaryDirectory())
        config.setStateForTesting(configuration: Configuration(
            version: 1, debounceMs: nil,
            screens: [ScreenAlias(alias: "portrait", nameContains: "U2723QE")],
            rules: [Rule(app: AppMatcher(bundleId: bundleId, nameContains: nil),
                         targetScreen: "portrait", profileOverrides: nil)],
            profiles: nil, windowFilter: nil
        ))
        let store = LayoutSnapshotStore(snapshotDirectory: temporaryDirectory(), loadExisting: false,
                                        screenDetector: detector)
        let manager = RuleTestWindowManager()
        let service = RuleApplyService(screenSession: ScreenSessionService(screenDetector: detector),
                                       configManager: config, windowManager: manager, ruleEngine: RuleEngine(),
                                       snapshotStore: store, scheduleAfter: scheduleAfter)
        return Fixture(service: service, detector: detector, config: config, store: store,
                       manager: manager, portrait: portrait, landscape: landscape, screens: screens)
    }

    private func launch(_ fixture: Fixture) {
        var completed = false
        fixture.service.handleAppLaunch(bundleId: bundleId, appName: "Ghostty") { result in
            XCTAssertEqual(result?.targetScreenAlias, "portrait")
            completed = true
        }
        XCTAssertTrue(completed)
    }

    private func makeOrchestrator(_ fixture: Fixture) -> Orchestrator {
        Orchestrator(
            screenDetector: fixture.detector, configManager: fixture.config,
            windowManager: fixture.manager, snapshotStore: fixture.store,
            snapBarController: SnapBarController(windowManager: fixture.manager, shouldStartPolling: false),
            autoUpdater: AutoUpdater(autoCheckOnLaunch: false),
            settingsStore: MenuSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            isAccessibilityTrusted: { true }, requestAccessibilityAccess: {}, scheduleAfter: { _, _ in },
            powerMonitor: PowerStateMonitor(observe: false),
            enableAppLaunchObserver: false, enableAutoSaveTimer: false
        )
    }

    private func save(_ windows: [WindowSnapshot], in fixture: Fixture, profileKey: String = "desk") {
        fixture.store.save(snapshot: LayoutSnapshot(profileKey: profileKey, profileLabel: "Desk",
                                                   timestamp: Date(), windows: windows))
    }

    private func savedWindow(title: String = "Terminal", frame: CGRect,
                             screen: ScreenInfo, screens: [ScreenInfo]) -> WindowSnapshot {
        let screenFrame = CoordinateConverter.accessibilityScreenFrame(for: screen, screens: screens)!
        return WindowSnapshot(bundleId: bundleId, appName: "Ghostty", windowTitle: title,
                              frame: .init(frame), screenName: screen.name, screenKey: screen.uniqueKey,
                              relativeFrame: .relative(from: frame, in: screenFrame),
                              windowRole: "AXWindow", windowSubrole: "AXStandardWindow")
    }

    private func runningWindow(title: String = "Terminal", pid: pid_t = 100,
                               frame: CGRect = CGRect(x: 100, y: -1000, width: 482, height: 800)) -> WindowManager.WindowInfo {
        WindowManager.WindowInfo(pid: pid, bundleId: bundleId, appName: "Ghostty", title: title,
                                 role: "AXWindow", subrole: "AXStandardWindow", isMinimized: false,
                                 frame: frame, axWindow: AXUIElementCreateApplication(pid))
    }

    private func screen(id: UInt32, name: String, frame: CGRect) -> ScreenInfo {
        ScreenInfo(displayID: id, name: name, frame: frame, isBuiltIn: id == 901,
                   position: .single, vendorID: id, modelID: id, serialNumber: id,
                   persistentID: "screen-\(id)")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
}

private final class RuleTestWindowManager: WindowManager {
    var windows: [WindowInfo] = []
    private(set) var moves: [(window: AXUIElement, frame: CGRect)] = []
    private(set) var fallbackMoves: [(window: AXUIElement, targetScreen: ScreenInfo)] = []

    override func getAllWindows() -> [WindowInfo] { windows }

    override func getWindows(bundleId: String) -> [WindowInfo] {
        windows.filter { $0.bundleId == bundleId }
    }

    override func moveWindow(_ window: AXUIElement, toFrame frame: CGRect) {
        moves.append((window, frame))
    }

    override func moveWindowToScreen(_ window: AXUIElement, currentFrame: CGRect, targetScreen: ScreenInfo) {
        fallbackMoves.append((window, targetScreen))
    }
}

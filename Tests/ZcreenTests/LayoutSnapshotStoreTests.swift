import XCTest
import ApplicationServices
@testable import Zcreen

final class LayoutSnapshotStoreTests: XCTestCase {

    func testRestoreAlsoChecksCurrentAppNameAgainstExclusions() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = makeWindowInfo(bundleId: "com.test.app", appName: "Excluded Edition",
                                     title: "Editor", frame: CGRect(x: 100, y: 100, width: 600, height: 400))
        let manager = RestoreCountingWindowManager(windows: [current])
        let store = LayoutSnapshotStore(snapshotDirectory: directory, loadExisting: false, runningBundleIds: { [] })
        let snapshot = LayoutSnapshot(profileKey: "main", profileLabel: "Main", timestamp: Date(),
            windows: [makeWindowSnapshot(bundleId: "com.test.app", appName: "Previous Name", title: "Editor")])
        store.restoreSnapshot(snapshot, windowManager: manager, excludeBundleIds: [],
            excludeAppMatchers: [AppMatcher(bundleId: nil, nameContains: "Excluded")],
            windowFilter: WindowFilter(configuration: .empty))
        XCTAssertEqual(manager.moveWindowCallCount, 0)
    }

    func testLegacySnapshotMigratesToCurrentDisplayUUIDAndSurvivesReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let detector = ScreenDetector(shouldRegisterCallback: false)
        detector.setStateForTesting(screens: [legacyScreen(id: 1, uuid: "uuid-main", serial: 1001)])
        let oldKey = "1-101-1001"
        let oldWindow = WindowSnapshot(bundleId: "com.test.app", appName: "Test", windowTitle: "Editor",
            frame: .init(CGRect(x: 100, y: 50, width: 600, height: 400)), screenName: "Main",
            screenKey: oldKey, relativeFrame: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            windowRole: "AXWindow", windowSubrole: "AXStandardWindow")
        let legacy = LayoutSnapshot(profileKey: oldKey, profileLabel: "Desk",
                                    timestamp: Date(timeIntervalSince1970: 1_000_000), windows: [oldWindow])
        let store = LayoutSnapshotStore(snapshotDirectory: directory, loadExisting: false, screenDetector: detector)
        XCTAssertTrue(store.save(snapshot: legacy))
        let originalFile = try XCTUnwrap(store.snapshotFileURL(for: oldKey))
        let migrated = try XCTUnwrap(store.load(profileKey: "uuid-main"))
        XCTAssertEqual(migrated.windows.first?.screenKey, "uuid-main")
        XCTAssertEqual(migrated.windows.first?.relativeFrame, oldWindow.relativeFrame)
        XCTAssertEqual(migrated.timestamp, legacy.timestamp)
        XCTAssertTrue(FileManager.default.fileExists(atPath: originalFile.path))
        let reloaded = LayoutSnapshotStore(snapshotDirectory: directory, screenDetector: detector)
        XCTAssertEqual(reloaded.load(profileKey: "uuid-main")?.windows, migrated.windows)
    }

    func testAmbiguousLegacyDisplaysAreNotMigratedByGuessing() {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let detector = ScreenDetector(shouldRegisterCallback: false)
        detector.setStateForTesting(screens: [legacyScreen(id: 1, uuid: "uuid-a", serial: 0),
                                             legacyScreen(id: 2, uuid: "uuid-b", serial: 0)])
        let store = LayoutSnapshotStore(snapshotDirectory: directory, loadExisting: false, screenDetector: detector)
        let legacy = LayoutSnapshot(profileKey: "1-101-0+1-101-0", profileLabel: "Desk", timestamp: Date(), windows: [])
        XCTAssertTrue(store.save(snapshot: legacy))
        XCTAssertNil(store.load(profileKey: "uuid-a+uuid-b"))
        XCTAssertNotNil(store.load(profileKey: legacy.profileKey))
        XCTAssertEqual(store.savedProfileCount, 1)
    }

    private func legacyScreen(id: UInt32, uuid: String, serial: UInt32) -> ScreenInfo {
        ScreenInfo(displayID: id, name: "Main", frame: CGRect(x: 0, y: 0, width: 1200, height: 800),
                   isBuiltIn: false, position: .single, vendorID: 1, modelID: 101,
                   serialNumber: serial, persistentID: uuid)
    }

    func testFailedWriteDoesNotPublishOrCacheSnapshot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("not a directory".utf8).write(to: directory)
        let store = LayoutSnapshotStore(snapshotDirectory: directory, loadExisting: false)
        store.save(snapshot: LayoutSnapshot(profileKey: "desk", profileLabel: "Desk", timestamp: Date(), windows: []))
        XCTAssertNil(store.load(profileKey: "desk"))
        XCTAssertEqual(store.savedProfileCount, 0)
    }

    func testSnapshotFileURLReturnsSavedJSONForProfile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = LayoutSnapshotStore(snapshotDirectory: directory, loadExisting: false)
        let snapshot = LayoutSnapshot(
            profileKey: "desk-profile",
            profileLabel: "Desk",
            timestamp: Date(),
            windows: []
        )

        store.save(snapshot: snapshot)

        let fileURL = try XCTUnwrap(store.snapshotFileURL(for: "desk-profile"))
        XCTAssertEqual(fileURL.pathExtension, "json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testCaptureSnapshotUsesAccessibilityScreenFrameForTallerExternalDisplay() throws {
        let mainScreen = makeScreen(
            displayID: 1,
            name: "Built-in Retina Display",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )
        let externalScreen = makeScreen(
            displayID: 2,
            name: "Dell U2723QE",
            frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440)
        )
        let windowFrame = CGRect(x: 1768, y: -170, width: 1280, height: 360)
        let windowManager = SnapshotTestWindowManager(window: makeWindowInfo(frame: windowFrame))
        let store = LayoutSnapshotStore(
            snapshotDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            loadExisting: false
        )

        let snapshot = store.captureSnapshot(
            profileKey: "dual",
            profileLabel: "Dual",
            windowManager: windowManager,
            screens: [mainScreen, externalScreen],
            windowFilter: WindowFilter(configuration: .empty)
        )
        let savedWindow = try XCTUnwrap(snapshot.windows.first)
        let relativeFrame = try XCTUnwrap(savedWindow.relativeFrame)

        XCTAssertEqual(savedWindow.screenKey, externalScreen.uniqueKey)
        XCTAssertEqual(savedWindow.screenName, externalScreen.name)
        XCTAssertEqual(relativeFrame.x, 0.1, accuracy: 0.001)
        XCTAssertEqual(relativeFrame.y, 0.2, accuracy: 0.001)
        XCTAssertEqual(relativeFrame.width, 0.5, accuracy: 0.001)
        XCTAssertEqual(relativeFrame.height, 0.25, accuracy: 0.001)
    }

    func testCaptureSnapshotSkipsFloatingAndExcludedWindows() {
        let mainScreen = makeScreen(
            displayID: 1,
            name: "Built-in Retina Display",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )
        let windows = [
            makeWindowInfo(
                bundleId: "com.google.Chrome",
                appName: "Google Chrome",
                title: "Main",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                frame: CGRect(x: 100, y: 100, width: 1200, height: 800)
            ),
            makeWindowInfo(
                bundleId: "com.google.Chrome",
                appName: "Google Chrome",
                title: "Palette",
                role: "AXWindow",
                subrole: "AXFloatingWindow",
                frame: CGRect(x: 20, y: 20, width: 300, height: 200)
            ),
            makeWindowInfo(
                bundleId: "com.apple.finder",
                appName: "Finder",
                title: "Downloads",
                role: "AXWindow",
                subrole: "AXStandardWindow",
                frame: CGRect(x: 200, y: 150, width: 900, height: 700)
            ),
        ]
        let windowManager = SnapshotTestWindowManager(windows: windows)
        let store = LayoutSnapshotStore(
            snapshotDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            loadExisting: false
        )
        let config = Configuration(
            version: 1,
            debounceMs: 500,
            screens: nil,
            rules: nil,
            profiles: nil,
            windowFilter: WindowFilterConfig(
                excludedApps: [AppMatcher(bundleId: "com.apple.finder", nameContains: nil)],
                excludedRoles: nil,
                excludedSubroles: nil,
                minWidth: nil,
                minHeight: nil,
                excludeMinimized: true
            )
        )

        let snapshot = store.captureSnapshot(
            profileKey: "single",
            profileLabel: "Single",
            windowManager: windowManager,
            screens: [mainScreen],
            windowFilter: WindowFilter(configuration: config)
        )

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.bundleId, "com.google.Chrome")
        XCTAssertEqual(snapshot.windows.first?.windowTitle, "Main")
    }

    func testCaptureSnapshotSkipsExplicitlyExcludedApps() {
        let mainScreen = makeScreen(
            displayID: 1,
            name: "Built-in Retina Display",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982)
        )
        let windows = [
            makeWindowInfo(
                bundleId: "com.mitchellh.ghostty",
                appName: "Ghostty",
                title: "Claude",
                frame: CGRect(x: 216, y: 33, width: 1080, height: 898)
            ),
            makeWindowInfo(
                bundleId: "com.google.Chrome",
                appName: "Google Chrome",
                title: "Browser",
                frame: CGRect(x: 0, y: 33, width: 1512, height: 898)
            ),
        ]
        let windowManager = SnapshotTestWindowManager(windows: windows)
        let store = LayoutSnapshotStore(
            snapshotDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            loadExisting: false
        )

        let snapshot = store.captureSnapshot(
            profileKey: "single",
            profileLabel: "Single",
            windowManager: windowManager,
            screens: [mainScreen],
            excludeAppMatchers: [AppMatcher(bundleId: "com.mitchellh.ghostty", nameContains: nil)],
            windowFilter: WindowFilter(configuration: .empty)
        )

        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows.first?.bundleId, "com.google.Chrome")
    }

    func testRestoreSkipsSnapshotWindowsMatchingExcludedAppMatchers() {
        let ghostty = makeWindowInfo(
            bundleId: "com.mitchellh.ghostty",
            appName: "Ghostty",
            title: "Claude",
            frame: CGRect(x: 216, y: 33, width: 1080, height: 898)
        )
        let chrome = makeWindowInfo(
            bundleId: "com.google.Chrome",
            appName: "Google Chrome",
            title: "Browser",
            frame: CGRect(x: 0, y: 33, width: 1512, height: 898)
        )
        let windowManager = RestoreCountingWindowManager(windows: [ghostty, chrome])
        let store = LayoutSnapshotStore(
            snapshotDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            loadExisting: false
        )
        let snapshot = LayoutSnapshot(
            profileKey: "dual",
            profileLabel: "Dual",
            timestamp: Date(),
            windows: [
                makeWindowSnapshot(bundleId: "com.mitchellh.ghostty", appName: "Ghostty", title: "Claude"),
                makeWindowSnapshot(bundleId: "com.google.Chrome", appName: "Google Chrome", title: "Browser"),
            ]
        )

        store.restoreSnapshot(
            snapshot,
            windowManager: windowManager,
            excludeBundleIds: [],
            excludeAppMatchers: [AppMatcher(bundleId: "com.mitchellh.ghostty", nameContains: nil)],
            windowFilter: WindowFilter(configuration: .empty)
        )

        XCTAssertEqual(windowManager.moveWindowCallCount, 1)
    }

    private func makeScreen(displayID: CGDirectDisplayID, name: String, frame: CGRect) -> ScreenInfo {
        ScreenInfo(
            displayID: displayID,
            name: name,
            frame: frame,
            isBuiltIn: displayID == 1,
            position: .single,
            vendorID: displayID,
            modelID: 100 + displayID,
            serialNumber: 1000 + displayID
        )
    }

    private func makeWindowInfo(bundleId: String = "com.test.app", appName: String = "Test App",
                                title: String? = "Editor", role: String? = "AXWindow",
                                subrole: String? = "AXStandardWindow", frame: CGRect,
                                isMinimized: Bool = false) -> WindowManager.WindowInfo {
        WindowManager.WindowInfo(
            pid: 1,
            bundleId: bundleId,
            appName: appName,
            title: title,
            role: role,
            subrole: subrole,
            isMinimized: isMinimized,
            frame: frame,
            axWindow: AXUIElementCreateSystemWide()
        )
    }

    private func makeWindowSnapshot(bundleId: String, appName: String, title: String) -> WindowSnapshot {
        WindowSnapshot(
            bundleId: bundleId,
            appName: appName,
            windowTitle: title,
            frame: .init(CGRect(x: 10, y: 20, width: 600, height: 400)),
            screenName: "Built-in Retina Display",
            screenKey: nil,
            relativeFrame: nil,
            windowRole: "AXWindow",
            windowSubrole: "AXStandardWindow"
        )
    }
}

private final class SnapshotTestWindowManager: WindowManager {
    private let windows: [WindowInfo]

    init(window: WindowInfo) {
        self.windows = [window]
        super.init()
    }

    init(windows: [WindowInfo]) {
        self.windows = windows
        super.init()
    }

    override func getAllWindows() -> [WindowInfo] {
        windows
    }
}

private final class RestoreCountingWindowManager: WindowManager {
    private let windows: [WindowInfo]
    private(set) var moveWindowCallCount = 0

    init(windows: [WindowInfo]) {
        self.windows = windows
        super.init()
    }

    override func getAllWindows() -> [WindowInfo] {
        windows
    }

    override func moveWindow(_ window: AXUIElement, toFrame frame: CGRect) {
        moveWindowCallCount += 1
    }
}

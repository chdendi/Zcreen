import XCTest
@testable import Zcreen

final class SnapshotServiceTests: XCTestCase {

    func testSavePreservesEntriesForAppsMissingFromCapture() {
        // AX returned nothing for app B in this capture (busy / mid-launch).
        // Its saved windows must survive the save instead of being dropped.
        let fixture = makeFixture()
        let existingA = makeWindow(bundleId: "com.test.a", title: "A old", x: 10)
        let existingB = makeWindow(bundleId: "com.test.b", title: "B", x: 500)
        fixture.store.storedSnapshots["main"] = makeSnapshot(windows: [existingA, existingB])

        let capturedA = makeWindow(bundleId: "com.test.a", title: "A new", x: 42)
        fixture.store.nextCapturedSnapshot = makeSnapshot(windows: [capturedA])

        let result = fixture.service.saveCurrentLayout(trigger: .periodic, force: false)

        guard case .saved(let windowCount) = result else {
            return XCTFail("Expected .saved, got \(result)")
        }
        XCTAssertEqual(windowCount, 2)
        let saved = fixture.store.storedSnapshots["main"]
        XCTAssertEqual(saved?.windows.count, 2)
        XCTAssertTrue(saved?.windows.contains(capturedA) == true, "Captured windows are taken as-is")
        XCTAssertTrue(saved?.windows.contains(existingB) == true, "Missing app's windows must be preserved")
        XCTAssertFalse(saved?.windows.contains(existingA) == true, "Stale entries of captured apps are replaced")
    }

    func testSaveSkipsWhenMergedLayoutMatchesExisting() {
        // Capture lost app B but app A is unchanged — after merging, the result
        // is identical to the stored snapshot, so nothing should be written.
        let fixture = makeFixture()
        let windowA = makeWindow(bundleId: "com.test.a", title: "A", x: 10)
        let windowB = makeWindow(bundleId: "com.test.b", title: "B", x: 500)
        fixture.store.storedSnapshots["main"] = makeSnapshot(windows: [windowA, windowB])
        fixture.store.nextCapturedSnapshot = makeSnapshot(windows: [windowA])

        let result = fixture.service.saveCurrentLayout(trigger: .periodic, force: false)

        guard case .unchanged = result else {
            return XCTFail("Expected .unchanged, got \(result)")
        }
        XCTAssertEqual(fixture.store.saveCallCount, 0)
    }

    func testForcedManualSaveStillPreservesMissingApps() {
        let fixture = makeFixture()
        let existingB = makeWindow(bundleId: "com.test.b", title: "B", x: 500)
        fixture.store.storedSnapshots["main"] = makeSnapshot(windows: [existingB])
        fixture.store.nextCapturedSnapshot = makeSnapshot(windows: [makeWindow(bundleId: "com.test.a", title: "A", x: 10)])

        let result = fixture.service.saveCurrentLayout(trigger: .manual, force: true)

        guard case .saved(let windowCount) = result else {
            return XCTFail("Expected .saved, got \(result)")
        }
        XCTAssertEqual(windowCount, 2)
        XCTAssertTrue(fixture.store.storedSnapshots["main"]?.windows.contains(existingB) == true)
    }

    func testSavePassesConfiguredRuleAppsAsCaptureExclusions() {
        let fixture = makeFixture(
            configuration: Configuration(
                version: 1,
                debounceMs: 500,
                screens: nil,
                rules: [
                    Rule(
                        app: AppMatcher(bundleId: "com.mitchellh.ghostty", nameContains: nil),
                        targetScreen: "portrait",
                        profileOverrides: nil
                    )
                ],
                profiles: nil,
                windowFilter: nil
            )
        )
        fixture.store.nextCapturedSnapshot = makeSnapshot(windows: [makeWindow(bundleId: "com.test.a", title: "A", x: 10)])

        _ = fixture.service.saveCurrentLayout(trigger: .periodic, force: false)

        XCTAssertEqual(fixture.store.lastExcludeAppMatchers.first?.bundleId, "com.mitchellh.ghostty")
    }

    // MARK: - Fixture

    private struct Fixture {
        let service: SnapshotService
        let store: StubSnapshotStore
    }

    private func makeFixture(configuration: Configuration = .empty) -> Fixture {
        let detector = ScreenDetector(shouldRegisterCallback: false)
        detector.setStateForTesting(
            screens: [ScreenInfo(
                displayID: 1,
                name: "Built-in Retina Display",
                frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
                isBuiltIn: true,
                position: .single,
                vendorID: 1,
                modelID: 101,
                serialNumber: 1001
            )],
            profileKey: "main",
            profileLabel: "Main"
        )
        let store = StubSnapshotStore()
        let configManager = ConfigManager(
            loadFromDisk: false,
            configDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        configManager.setStateForTesting(configuration: configuration)
        let service = SnapshotService(
            screenSession: ScreenSessionService(screenDetector: detector),
            configManager: configManager,
            windowManager: WindowManager(),
            snapshotStore: store
        )
        return Fixture(service: service, store: store)
    }

    private func makeSnapshot(windows: [WindowSnapshot]) -> LayoutSnapshot {
        LayoutSnapshot(
            profileKey: "main",
            profileLabel: "Main",
            timestamp: Date(timeIntervalSince1970: 1_000_000),
            windows: LayoutSnapshotStore.sortedForSnapshot(windows)
        )
    }

    private func makeWindow(bundleId: String, title: String, x: CGFloat) -> WindowSnapshot {
        WindowSnapshot(
            bundleId: bundleId,
            appName: bundleId,
            windowTitle: title,
            frame: .init(CGRect(x: x, y: 30, width: 600, height: 400)),
            screenName: "Main",
            screenKey: "screen-key-main",
            relativeFrame: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
            windowRole: "AXWindow",
            windowSubrole: "AXStandardWindow"
        )
    }
}

private final class StubSnapshotStore: LayoutSnapshotStore {
    var nextCapturedSnapshot = LayoutSnapshot(profileKey: "", profileLabel: "", timestamp: Date(), windows: [])
    var storedSnapshots: [String: LayoutSnapshot] = [:]
    private(set) var lastExcludeAppMatchers: [AppMatcher] = []
    private(set) var saveCallCount = 0

    init() {
        super.init(
            snapshotDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            loadExisting: false
        )
    }

    override func save(snapshot: LayoutSnapshot) {
        saveCallCount += 1
        storedSnapshots[snapshot.profileKey] = snapshot
    }

    override func load(profileKey: String) -> LayoutSnapshot? {
        storedSnapshots[profileKey]
    }

    override func captureSnapshot(profileKey: String, profileLabel: String, windowManager: WindowManager,
                                  screens: [ScreenInfo], excludeAppMatchers: [AppMatcher],
                                  windowFilter: WindowFilter) -> LayoutSnapshot {
        lastExcludeAppMatchers = excludeAppMatchers
        return nextCapturedSnapshot
    }
}

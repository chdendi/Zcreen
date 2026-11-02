import XCTest
import ApplicationServices
@testable import Zcreen

final class SnapshotServiceTests: XCTestCase {

    func testSaveFailureIsReportedInsteadOfClaimingSuccess() {
        let fixture = makeFixture()
        fixture.store.shouldSave = false
        fixture.store.nextCapturedSnapshot = makeSnapshot(windows: [makeWindow(bundleId: "a", title: "A", x: 10)])
        guard case .failed = fixture.service.saveCurrentLayout(trigger: .manual, force: true) else {
            return XCTFail("Expected a failed save result")
        }
        XCTAssertNil(fixture.store.storedSnapshots["main"])
    }

    func testEmptyCaptureRemovesExplicitExclusionsAndKeepsMissingAllowedApps() {
        let fixture = makeFixture(configuration: configurationExcludingAppB())
        let allowed = makeWindow(bundleId: "com.test.a", title: "A", x: 10)
        let managed = makeWindow(bundleId: "com.test.b", title: "B", x: 500)
        fixture.store.storedSnapshots["main"] = makeSnapshot(windows: [allowed, managed])
        fixture.store.nextCapturedSnapshot = makeSnapshot(windows: [])
        guard case .saved(let count) = fixture.service.saveCurrentLayout(trigger: .periodic, force: false) else {
            return XCTFail("Explicit exclusions should be removed from the stored layout")
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(fixture.store.storedSnapshots["main"]?.windows, [allowed])
    }

    func testMergeRemovesPreviouslySavedExplicitlyExcludedApps() {
        let fixture = makeFixture(configuration: configurationExcludingAppB())
        let windowA = makeWindow(bundleId: "com.test.a", title: "A", x: 10)
        let windowB = makeWindow(bundleId: "com.test.b", title: "B", x: 500)
        fixture.store.storedSnapshots["main"] = makeSnapshot(windows: [windowA, windowB])
        fixture.store.nextCapturedSnapshot = makeSnapshot(windows: [windowA])
        _ = fixture.service.saveCurrentLayout(trigger: .periodic, force: false)
        XCTAssertEqual(fixture.store.storedSnapshots["main"]?.windows, [windowA])
    }

    func testMissingRuleManagedAppKeepsItsSavedGeometry() {
        let fixture = makeFixture(configuration: Configuration(version: 1, debounceMs: nil, screens: nil,
            rules: [Rule(app: AppMatcher(bundleId: "com.test.b", nameContains: nil),
                         targetScreen: "main", profileOverrides: nil)], profiles: nil, windowFilter: nil))
        let windowA = makeWindow(bundleId: "com.test.a", title: "A", x: 10)
        let windowB = makeWindow(bundleId: "com.test.b", title: "B", x: 500)
        fixture.store.storedSnapshots["main"] = makeSnapshot(windows: [windowB])
        fixture.store.nextCapturedSnapshot = makeSnapshot(windows: [windowA])
        _ = fixture.service.saveCurrentLayout(trigger: .periodic, force: false)
        XCTAssertEqual(fixture.store.storedSnapshots["main"]?.windows, [windowA, windowB])
    }

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

    func testSaveIncludesConfiguredRuleAppsInCapture() {
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
        let ghostty = makeWindow(bundleId: "com.mitchellh.ghostty", title: "Terminal", x: 10)
        fixture.store.nextCapturedSnapshot = makeSnapshot(windows: [ghostty])

        _ = fixture.service.saveCurrentLayout(trigger: .periodic, force: false)

        XCTAssertTrue(fixture.store.lastExcludeAppMatchers.isEmpty)
        XCTAssertEqual(fixture.store.storedSnapshots["main"]?.windows, [ghostty])
    }

    // MARK: - Restore guard

    func testUnplacedWindowCannotOverwriteSavedSlotUntilTheUserMovesIt() {
        let fixture = makeFixture()
        let savedLeft = makeWindow(bundleId: "com.test.a", title: "Left", x: 10)
        fixture.store.storedSnapshots["main"] = makeSnapshot(windows: [savedLeft])
        let orphan = AXUIElementCreateApplication(900)
        let evicted = CGRect(x: 300, y: 30, width: 600, height: 400)
        fixture.store.restoreOutcome = RestoreOutcome(
            profileKey: "main", placedCount: 0, drifted: [],
            orphans: [.init(window: orphan, bundleId: "com.test.a", frame: evicted)],
            unresolved: [savedLeft]
        )
        _ = fixture.service.restoreLayout(profileKey: "main", profileLabel: "Main")

        // macOS left the window where it evicted it; the save must keep the saved slot.
        capture(fixture, [(makeWindow(bundleId: "com.test.a", title: "Untitled", x: 300), orphan)])
        guard case .unchanged = fixture.service.saveCurrentLayout(trigger: .screenChange, force: false) else {
            return XCTFail("An untouched unplaced window must not replace its saved slot")
        }
        XCTAssertEqual(fixture.store.storedSnapshots["main"]?.windows, [savedLeft])

        // Once the user moves it, its new position is saved.
        let moved = makeWindow(bundleId: "com.test.a", title: "Untitled", x: 700)
        capture(fixture, [(moved, orphan)])
        _ = fixture.service.saveCurrentLayout(trigger: .periodic, force: false)
        XCTAssertTrue(fixture.store.storedSnapshots["main"]?.windows.contains(moved) == true)

        // After the guard lifetime the regular merge takes over again.
        fixture.clock.advance(by: Constants.Timing.restoreGuardLifetime + 1)
        _ = fixture.service.saveCurrentLayout(trigger: .periodic, force: false)
        XCTAssertEqual(fixture.store.storedSnapshots["main"]?.windows, [moved])
    }

    func testDriftedWindowKeepsItsSavedEntryUntilMoved() {
        let fixture = makeFixture()
        let savedRight = makeWindow(bundleId: "com.test.a", title: "Right", x: 900)
        let other = makeWindow(bundleId: "com.test.b", title: "B", x: 10)
        fixture.store.storedSnapshots["main"] = makeSnapshot(windows: [savedRight, other])
        let element = AXUIElementCreateApplication(901)
        fixture.store.restoreOutcome = RestoreOutcome(
            profileKey: "main", placedCount: 1,
            drifted: [.init(window: element, saved: savedRight, frame: CGRect(x: 400, y: 30, width: 600, height: 400))],
            orphans: [], unresolved: []
        )
        _ = fixture.service.restoreLayout(profileKey: "main", profileLabel: "Main")

        capture(fixture, [(makeWindow(bundleId: "com.test.a", title: "Right", x: 400), element), (other, nil)])
        _ = fixture.service.saveCurrentLayout(trigger: .periodic, force: false)
        XCTAssertEqual(fixture.store.storedSnapshots["main"]?.windows, [savedRight, other])

        let moved = makeWindow(bundleId: "com.test.a", title: "Right", x: 1200)
        capture(fixture, [(moved, element), (other, nil)])
        _ = fixture.service.saveCurrentLayout(trigger: .periodic, force: false)
        XCTAssertEqual(fixture.store.storedSnapshots["main"]?.windows, makeSnapshot(windows: [moved, other]).windows)
    }

    func testManualSaveDropsTheRestoreGuard() {
        let fixture = makeFixture()
        let savedLeft = makeWindow(bundleId: "com.test.a", title: "Left", x: 10)
        fixture.store.storedSnapshots["main"] = makeSnapshot(windows: [savedLeft])
        let orphan = AXUIElementCreateApplication(902)
        fixture.store.restoreOutcome = RestoreOutcome(
            profileKey: "main", placedCount: 0, drifted: [],
            orphans: [.init(window: orphan, bundleId: "com.test.a", frame: CGRect(x: 300, y: 30, width: 600, height: 400))],
            unresolved: [savedLeft]
        )
        _ = fixture.service.restoreLayout(profileKey: "main", profileLabel: "Main")

        let current = makeWindow(bundleId: "com.test.a", title: "Untitled", x: 300)
        capture(fixture, [(current, orphan)])
        _ = fixture.service.saveCurrentLayout(trigger: .manual, force: true)
        XCTAssertEqual(fixture.store.storedSnapshots["main"]?.windows, [current])
    }

    func testCompleteRestoreInstallsNoGuard() {
        let fixture = makeFixture()
        let saved = makeWindow(bundleId: "com.test.a", title: "A", x: 10)
        fixture.store.storedSnapshots["main"] = makeSnapshot(windows: [saved])
        fixture.store.restoreOutcome = RestoreOutcome(profileKey: "main", placedCount: 1, drifted: [], orphans: [], unresolved: [])
        _ = fixture.service.restoreLayout(profileKey: "main", profileLabel: "Main")

        let moved = makeWindow(bundleId: "com.test.a", title: "A", x: 500)
        capture(fixture, [(moved, AXUIElementCreateApplication(903))])
        _ = fixture.service.saveCurrentLayout(trigger: .periodic, force: false)
        XCTAssertEqual(fixture.store.storedSnapshots["main"]?.windows, [moved])
    }

    func testCaptureIsDiscardedWhenValidationFails() {
        let fixture = makeFixture()
        fixture.store.nextCapturedSnapshot = makeSnapshot(windows: [makeWindow(bundleId: "a", title: "A", x: 10)])
        guard case .discarded = fixture.service.saveCurrentLayout(trigger: .screenWillChange, force: false,
                                                                    validate: { false }) else {
            return XCTFail("A capture that raced a display change must be discarded")
        }
        XCTAssertEqual(fixture.store.saveCallCount, 0)
    }

    func testAutomaticSaveWaitsForInFlightRestore() {
        let fixture = makeFixture()
        fixture.store.inFlight = true
        fixture.store.nextCapturedSnapshot = makeSnapshot(windows: [makeWindow(bundleId: "a", title: "A", x: 10)])
        guard case .deferred = fixture.service.saveCurrentLayout(trigger: .periodic, force: false) else {
            return XCTFail("Automatic saves must not capture windows mid-restore")
        }
        guard case .saved = fixture.service.saveCurrentLayout(trigger: .manual, force: true) else {
            return XCTFail("A manual save still goes through")
        }
    }

    func testSaveRemembersWindowIdentities() {
        let fixture = makeFixture()
        let window = makeWindow(bundleId: "a", title: "A", x: 10)
        let element = AXUIElementCreateApplication(904)
        capture(fixture, [(window, element)])
        _ = fixture.service.saveCurrentLayout(trigger: .periodic, force: false)
        let known = fixture.store.identityElements(for: [window], profileKey: "main")
        XCTAssertTrue(known.first.flatMap { $0 }.map { CFEqual($0, element) } == true)
    }

    private func capture(_ fixture: Fixture, _ windows: [(WindowSnapshot, AXUIElement?)]) {
        let sorted = windows.sorted { LayoutSnapshotStore.compareWindowSnapshots($0.0, $1.0) }
        fixture.store.nextCapturedSnapshot = makeSnapshot(windows: sorted.map(\.0))
        fixture.store.nextCapturedElements = sorted.map(\.1)
    }

    // MARK: - Fixture

    private func configurationExcludingAppB() -> Configuration {
        Configuration(version: 1, debounceMs: nil, screens: nil, rules: nil, profiles: nil,
            windowFilter: WindowFilterConfig(excludedApps: [AppMatcher(bundleId: "com.test.b", nameContains: nil)],
                excludedRoles: nil, excludedSubroles: nil, minWidth: nil, minHeight: nil, excludeMinimized: nil))
    }

    private struct Fixture {
        let service: SnapshotService
        let store: StubSnapshotStore
        let clock: TestClock
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
        let clock = TestClock()
        let service = SnapshotService(
            screenSession: ScreenSessionService(screenDetector: detector),
            configManager: configManager,
            windowManager: WindowManager(),
            snapshotStore: store,
            now: { clock.now }
        )
        return Fixture(service: service, store: store, clock: clock)
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

private final class TestClock {
    private(set) var now = Date(timeIntervalSince1970: 2_000_000)
    func advance(by interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

private final class StubSnapshotStore: LayoutSnapshotStore {
    var shouldSave = true
    var inFlight = false
    var restoreOutcome: RestoreOutcome?
    var nextCapturedSnapshot = LayoutSnapshot(profileKey: "", profileLabel: "", timestamp: Date(), windows: [])
    var nextCapturedElements: [AXUIElement?] = []

    override var isRestoreInFlight: Bool { inFlight }

    override func restoreSnapshot(_ snapshot: LayoutSnapshot, windowManager: WindowManager,
                                  excludeAppMatchers: [AppMatcher], windowFilter: WindowFilter,
                                  completion: ((RestoreOutcome) -> Void)?) {
        if let restoreOutcome { completion?(restoreOutcome) }
    }
    var storedSnapshots: [String: LayoutSnapshot] = [:]
    private(set) var lastExcludeAppMatchers: [AppMatcher] = []
    private(set) var saveCallCount = 0

    init() {
        super.init(
            snapshotDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            loadExisting: false
        )
    }

    override func save(snapshot: LayoutSnapshot) -> Bool {
        saveCallCount += 1
        guard shouldSave else { return false }
        storedSnapshots[snapshot.profileKey] = snapshot
        return true
    }

    override func load(profileKey: String) -> LayoutSnapshot? {
        storedSnapshots[profileKey]
    }

    override func captureLayout(profileKey: String, profileLabel: String, windowManager: WindowManager,
                                screens: [ScreenInfo], excludeAppMatchers: [AppMatcher],
                                windowFilter: WindowFilter) -> CapturedLayout {
        lastExcludeAppMatchers = excludeAppMatchers
        return CapturedLayout(snapshot: nextCapturedSnapshot, elements: nextCapturedElements)
    }
}

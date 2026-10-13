@testable import AppBundle
import Common
import XCTest

@MainActor final class AppLauncherSessionAdmissionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
        config.preventFocusStealing = .always
    }
    override func tearDown() async throws {
        TrayMenuModel.shared.isEnabled = true
        resetFocusCacheForTests()
        resetFocusStealingPreventionForTests()
    }
    func testPauseDuringCurrentWorkspaceLauncherQueryMustNotRestoreStaleFocus() async throws {
        try await exerciseDelayedQuery(crossWorkspace: false, resumeAgain: false)
    }
    func testPauseDuringCrossWorkspaceLauncherQueryMustNotRestoreOrRebind() async throws {
        try await exerciseDelayedQuery(crossWorkspace: true, resumeAgain: false)
    }
    func testPauseThenResumeStillSupersedesOlderLauncherQuery() async throws {
        try await exerciseDelayedQuery(crossWorkspace: true, resumeAgain: true)
    }
    func testPauseDuringInitialQueryDoesNotRebindUnmanagedNativeWindow() async throws {
        config.enableWindowManagement = false
        try await exerciseDelayedQuery(crossWorkspace: true, resumeAgain: false, unmanaged: true)
    }
    private func exerciseDelayedQuery(crossWorkspace: Bool, resumeAgain: Bool, unmanaged: Bool = false) async throws {
        let old = TestWindow.new(id: 301, parent: Workspace.get(byName: "old").rootTilingContainer)
        let selected = TestWindow.new(id: 302, parent: Workspace.get(byName: crossWorkspace ? "selected" : "old").rootTilingContainer)
        let external = TestWindow.new(id: 303, parent: Workspace.get(byName: "external").rootTilingContainer, rect: unmanaged ? Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 200) : nil)
        let externalWorkspace = external.nodeWorkspace
        XCTAssertTrue(old.focusWindow())
        old.nativeFocus()
        _ = updateFocusCache(old)
        let selectedWorkspace = selected.nodeWorkspace
        let admissionCheck = captureEnabledSessionAdmission()
        var queries = 0
        var actions = 0
        var now = ContinuousClock().now
        let clock = FocusStealingPreventionState(now: { now })
        clock.markUserInitiatedFocusChange()
        appForTests = DelayedLauncherFixtureApp {
            queries += 1
            await Task.yield()
            now = now.advanced(by: .seconds(2))
            XCTAssertFalse(clock.isUserInitiatedFocusChange)
            _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
            external.nativeFocus()
            resetFocusStealingPreventionForTests() // Same expired-grace decision, no real clock sleep.
            if resumeAgain { _ = try await parseCommand("enable on").cmdOrDie.run(.defaultEnv, .emptyStdin) }
            return external
        }
        do {
            try await runAppLauncherWindowSession(selected, admissionCheck: admissionCheck) {
                actions += 1
                if crossWorkspace { _ = selected.bindAsFloatingWindow(to: old.nodeWorkspace!) }
                _ = selected.focusWindow()
            }
            XCTFail("Pause must cancel the queued selection before initial sync applies")
        } catch is CancellationError {}
        XCTAssertEqual(queries, 1)
        XCTAssertEqual(actions, 0)
        XCTAssertEqual(TrayMenuModel.shared.isEnabled, resumeAgain)
        XCTAssertTrue(focus.windowOrNil === old)
        XCTAssertTrue(TestApp.shared.focusedWindow === external)
        XCTAssertTrue(selected.nodeWorkspace === selectedWorkspace)
        XCTAssertTrue(external.nodeWorkspace === externalWorkspace)
    }
    func testPauseBeforeQueuedSessionStartsDoesNotQueryOrAct() async throws {
        let selected = TestWindow.new(id: 304, parent: Workspace.get(byName: "selected").rootTilingContainer)
        let admissionCheck = captureEnabledSessionAdmission()
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        var queries = 0
        var actions = 0
        appForTests = DelayedLauncherFixtureApp { queries += 1; return selected }
        do {
            try await runAppLauncherWindowSession(selected, admissionCheck: admissionCheck) { actions += 1 }
            XCTFail("Superseded queued session must stop at entry")
        } catch is CancellationError {}
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(actions, 0)
    }
    func testAdmittedLauncherSessionStillFocusesSelection() async throws {
        let old = TestWindow.new(id: 305, parent: Workspace.get(byName: "old").rootTilingContainer)
        let selected = TestWindow.new(id: 306, parent: Workspace.get(byName: "selected").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        old.nativeFocus()
        let admissionCheck = captureEnabledSessionAdmission()
        var actions = 0
        appForTests = DelayedLauncherFixtureApp { await Task.yield(); return old }
        try await runAppLauncherWindowSession(selected, admissionCheck: admissionCheck) {
            actions += 1
            _ = selected.focusWindow()
        }
        XCTAssertEqual(actions, 1)
        XCTAssertTrue(focus.windowOrNil === selected)
        XCTAssertTrue(TestApp.shared.focusedWindow === selected)
    }
}

private final class DelayedLauncherFixtureApp: AbstractApp {
    let pid: Int32 = 999_301
    let rawAppBundleId: String? = "fixture.launcher"
    let name: String? = "Fixture"
    let execPath: String? = nil
    let bundlePath: String? = nil
    private let query: @MainActor () async throws -> Window?
    init(_ query: @MainActor @escaping () async throws -> Window?) { self.query = query }
    @MainActor func getFocusedWindow() async throws -> Window? { try await query() }
}

@testable import AppBundle
import Common
import XCTest

@MainActor
final class EnabledSessionAdmissionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
        config.preventFocusStealing = .always
    }

    override func tearDown() async throws {
        sessionCoordinator.setEnabled(true)
        resetFocusCacheForTests()
        resetFocusStealingPreventionForTests()
    }

    func testPauseBeforeQueuedActionStartsPreventsQueryAndBody() async throws {
        let token = try XCTUnwrap(RunSessionGuard.isServerEnabled)
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        var queries = 0
        var actions = 0
        appForTests = EnabledSessionFixtureApp { queries += 1; return nil }
        do {
            try await runLightSession(.menuBarButton, token) { actions += 1 }
            XCTFail("A queued selection must stop at entry after Pause")
        } catch is CancellationError {}
        XCTAssertEqual(queries, 0)
        XCTAssertEqual(actions, 0)
    }

    func testPauseDuringQueryPreventsFocusSyncAndBody() async throws {
        try await exerciseDelayedSelection(resumeAgain: false)
    }

    func testPauseThenResumeDuringQueryStillInvalidatesSelection() async throws {
        try await exerciseDelayedSelection(resumeAgain: true)
    }

    private func exerciseDelayedSelection(resumeAgain: Bool) async throws {
        let old = TestWindow.new(id: 401, parent: Workspace.get(byName: "old").rootTilingContainer)
        let external = TestWindow.new(id: 402, parent: Workspace.get(byName: "external").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        old.nativeFocus()
        _ = updateFocusCache(old)
        let token = try XCTUnwrap(RunSessionGuard.isServerEnabled)
        var actions = 0
        appForTests = EnabledSessionFixtureApp {
            await Task.yield()
            _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
            if resumeAgain { _ = try await parseCommand("enable on").cmdOrDie.run(.defaultEnv, .emptyStdin) }
            external.nativeFocus()
            resetFocusStealingPreventionForTests()
            return external
        }
        do {
            try await runLightSession(.menuBarButton, token) { actions += 1 }
            XCTFail("Pause must invalidate a selection suspended in its native-focus query")
        } catch is CancellationError {}
        XCTAssertEqual(actions, 0)
        XCTAssertTrue(focus.windowOrNil === old)
        XCTAssertTrue(TestApp.shared.focusedWindow === external)
        XCTAssertEqual(TrayMenuModel.shared.isEnabled, resumeAgain)
    }

    func testCurrentSelectionRunsNormally() async throws {
        let token = try XCTUnwrap(RunSessionGuard.isServerEnabled)
        appForTests = EnabledSessionFixtureApp { await Task.yield(); return nil }
        var actions = 0
        try await runLightSession(.menuBarButton, token) { actions += 1 }
        XCTAssertEqual(actions, 1)
    }

    func testSocketDispatchRejectsAnOrdinaryCommandAfterPause() async throws {
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        var queries = 0
        appForTests = EnabledSessionFixtureApp { queries += 1; return nil }
        let request = ClientRequest(args: ["focus", "left"], stdin: "", windowId: nil, workspace: nil)
        do {
            _ = try await runSocketCommandSession(parseCommand("focus left").cmdOrDie, request: request)
            XCTFail("A request accepted before Pause must be rejected when dispatched afterward")
        } catch is CancellationError {}
        XCTAssertEqual(queries, 0)
    }
}

private final class EnabledSessionFixtureApp: AbstractApp {
    let pid: Int32 = 999_401
    let rawAppBundleId: String? = "fixture.enabled-session"
    let name: String? = "Fixture"
    let execPath: String? = nil
    let bundlePath: String? = nil
    private let query: @MainActor () async throws -> Window?

    init(_ query: @MainActor @escaping () async throws -> Window?) { self.query = query }
    @MainActor func getFocusedWindow() async throws -> Window? { try await query() }
}

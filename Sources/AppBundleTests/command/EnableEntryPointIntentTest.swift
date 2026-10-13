@testable import AppBundle
import Common
import XCTest

@MainActor final class EnableEntryPointIntentTest: XCTestCase {
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
    func testSocketEnableOnCannotOverrideLaterSocketNoopOffDuringQuery() async throws {
        try await exercisePendingRequest(hotkey: false, laterUi: false)
    }
    func testSocketEnableOnCannotOverrideLaterUiNoopOffDuringQuery() async throws {
        try await exercisePendingRequest(hotkey: false, laterUi: true)
    }
    func testHotkeyToggleCannotOverrideLaterSocketOffDuringQuery() async throws {
        try await exercisePendingRequest(hotkey: true, laterUi: false)
    }
    func testPendingSocketOffInvalidatesLauncherBeforeItsQueryCompletes() async throws {
        let launcherAdmission = captureEnabledSessionAdmission()
        var queries = 0
        appForTests = EnableDispatchFixtureApp {
            queries += 1
            XCTAssertTrue(TrayMenuModel.shared.isEnabled) // Body has not paused yet.
            do {
                try launcherAdmission()
                XCTFail("Accepted CLI Pause must invalidate older launcher admission before AX returns")
            } catch is CancellationError {}
            await Task.yield()
            return nil
        }
        let answer = try await socket("enable off")
        XCTAssertEqual(answer.exitCode, 0)
        XCTAssertEqual(queries, 1)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
    }
    func testPausedSocketForceOnStillRunsAndParsedCommandCanBeReused() async throws {
        let reusable = parseCommand("enable on").cmdOrDie
        for _ in 0 ..< 2 {
            _ = try await socket("enable off")
            XCTAssertFalse(TrayMenuModel.shared.isEnabled)
            let request = ClientRequest(args: ["enable", "on"], stdin: "", windowId: nil, workspace: nil)
            let answer = try await runSocketCommandSession(reusable, request: request, token: .forceRun)
            XCTAssertEqual(answer.exitCode, 0)
            XCTAssertTrue(TrayMenuModel.shared.isEnabled)
            XCTAssertEqual(activeMode, mainModeId)
            XCTAssertNil((reusable as? EnableCommand)?.requestedIntent)
        }
    }
    func testHotkeySequenceKeepsNormalSequentialEnableSemanticsAndReusableCommands() async throws {
        let commands = [parseCommand("enable toggle").cmdOrDie, parseCommand("enable toggle").cmdOrDie]
        for _ in 0 ..< 2 {
            try await runHotkeyCommandSession(commands)
            XCTAssertTrue(TrayMenuModel.shared.isEnabled)
            XCTAssertEqual(activeMode, mainModeId)
            for command in commands { XCTAssertNil((command as? EnableCommand)?.requestedIntent) }
        }
    }
    func testSocketNoopExitFlagIsPreserved() async throws {
        _ = try await socket("enable off")
        let answer = try await socket("enable off --fail-if-noop")
        XCTAssertEqual(answer.exitCode, 1)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
    }
    private func exercisePendingRequest(hotkey: Bool, laterUi: Bool) async throws {
        let old = TestWindow.new(id: 321, parent: Workspace.get(byName: "old").rootTilingContainer)
        let external = TestWindow.new(id: 322, parent: Workspace.get(byName: "external").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        old.nativeFocus()
        _ = updateFocusCache(old)
        if !hotkey { _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin) }
        var queries = 0
        appForTests = EnableDispatchFixtureApp {
            queries += 1
            if queries > 1 { return nil }
            await Task.yield()
            if laterUi { try await runEnableCommandFromUi(.off) }
            else { _ = try await self.socket("enable off") }
            XCTAssertFalse(TrayMenuModel.shared.isEnabled)
            external.nativeFocus()
            resetFocusStealingPreventionForTests()
            return external
        }
        do {
            if hotkey { try await runHotkeyCommandSession([parseCommand("enable toggle").cmdOrDie]) }
            else { _ = try await socket("enable on") }
        } catch is CancellationError {}
        XCTAssertEqual(queries, 2)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertNil(activeMode)
        XCTAssertTrue(TestApp.shared.focusedWindow === external)
    }
    private func socket(_ text: String) async throws -> ServerAnswer {
        let command = parseCommand(text).cmdOrDie
        let request = ClientRequest(args: text.split(separator: " ").map(String.init), stdin: "", windowId: nil, workspace: nil)
        return try await runSocketCommandSession(command, request: request, token: .forceRun)
    }
}

private final class EnableDispatchFixtureApp: AbstractApp {
    let pid: Int32 = 999_321
    let rawAppBundleId: String? = "fixture.enable-dispatch"
    let name: String? = "Fixture"
    let execPath: String? = nil
    let bundlePath: String? = nil
    private let query: @MainActor () async throws -> Window?
    init(_ query: @MainActor @escaping () async throws -> Window?) { self.query = query }
    @MainActor func getFocusedWindow() async throws -> Window? { try await query() }
}

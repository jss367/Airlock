@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor final class NestedEnableIntentTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
    }
    override func tearDown() async throws {
        config.modes = [mainModeId: Mode(bindings: [:])]
        TrayMenuModel.shared.isEnabled = true
        resetFocusCacheForTests()
    }
    func testSocketNestedToggleReservesIntentBeforeInitialQuery() async throws {
        let nested = parseCommand("enable toggle").cmdOrDie
        let binding = HotkeyBinding(.option, .x, [nested], descriptionWithKeyNotation: "option-x")
        config.modes["fixture"] = Mode(bindings: [binding.descriptionWithKeyCode: binding])
        var queries = 0
        appForTests = NestedQueryFixtureApp {
            queries += 1
            if queries > 1 { return nil }
            await Task.yield()
            _ = try await self.socket("enable off")
            return nil
        }
        do {
            _ = try await socket("trigger-binding option-x --mode fixture")
            XCTFail("Newer Pause must cancel the nested Enable request before its body")
        } catch is CancellationError {}
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertEqual(queries, 2)
        XCTAssertNil((nested as? EnableCommand)?.requestedIntent)
    }
    func testNestedSequenceCanBeReusedWithoutInvalidatingItself() async throws {
        let nested = parseCommand("enable on").cmdOrDie
        let binding = HotkeyBinding(.option, .x, [nested], descriptionWithKeyNotation: "option-x")
        config.modes["fixture"] = Mode(bindings: [binding.descriptionWithKeyCode: binding])
        let trigger = parseCommand("trigger-binding option-x --mode fixture").cmdOrDie
        let commands = [trigger, parseCommand("enable off").cmdOrDie]
        for _ in 0 ..< 2 {
            _ = try await socket("enable on") // main has no bindings: never registers a real hotkey.
            try await runHotkeyCommandSession(commands)
            XCTAssertFalse(TrayMenuModel.shared.isEnabled)
            XCTAssertNil((nested as? EnableCommand)?.requestedIntent)
            XCTAssertTrue(trigger.equals(parseCommand("trigger-binding option-x --mode fixture").cmdOrDie))
        }
    }
    func testGenuinelyNewSocketRequestCancelsNestedAndOuterRemainder() async throws {
        try await exerciseNewRequest(ui: false)
    }
    func testGenuinelyNewUiRequestCancelsNestedAndOuterRemainder() async throws {
        try await exerciseNewRequest(ui: true)
    }
    private func exerciseNewRequest(ui: Bool) async throws {
        let binding = HotkeyBinding(.option, .x, [NestedNewRequestFixtureCommand(throughUi: ui), NestedTrailingFixtureCommand()], descriptionWithKeyNotation: "option-x")
        config.modes["fixture"] = Mode(bindings: [binding.descriptionWithKeyCode: binding])
        NestedTrailingFixtureCommand.calls = 0
        let commands = [parseCommand("trigger-binding option-x --mode fixture").cmdOrDie, parseCommand("enable on").cmdOrDie]
        do {
            try await runHotkeyCommandSession(commands)
            XCTFail("A separate socket request must supersede this invocation")
        } catch is CancellationError {}
        XCTAssertEqual(NestedTrailingFixtureCommand.calls, 0)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
    }
    private func socket(_ text: String) async throws -> ServerAnswer {
        let request = ClientRequest(args: text.split(separator: " ").map(String.init), stdin: "", windowId: nil, workspace: nil)
        return try await runSocketCommandSession(parseCommand(text).cmdOrDie, request: request, token: .forceRun)
    }
    func testNestedNoopEnableDoesNotCancelRemainingOuterPause() async throws {
        let nested = parseCommand("enable on").cmdOrDie
        let binding = HotkeyBinding(.option, .x, [nested], descriptionWithKeyNotation: "option-x")
        config.modes[mainModeId] = Mode(bindings: [binding.descriptionWithKeyCode: binding])
        let commands = [parseCommand("trigger-binding option-x --mode main").cmdOrDie, parseCommand("enable off").cmdOrDie]
        var cancelled = false
        do { try await runHotkeyCommandSession(commands) }
        catch is CancellationError { cancelled = true }
        XCTAssertFalse(cancelled)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertNil(activeMode)
        XCTAssertNil((nested as? EnableCommand)?.requestedIntent)
    }
}

private final class NestedQueryFixtureApp: AbstractApp {
    let pid: Int32 = 999_331
    let rawAppBundleId: String? = "fixture.nested"
    let name: String? = "Fixture"
    let execPath: String? = nil
    let bundlePath: String? = nil
    private let query: @MainActor () async throws -> Window?
    init(_ query: @MainActor @escaping () async throws -> Window?) { self.query = query }
    @MainActor func getFocusedWindow() async throws -> Window? { try await query() }
}
private struct NestedNewRequestFixtureCommand: Command {
    var throughUi = false
    let args = EnableCmdArgs(rawArgs: [], targetState: .off)
    let shouldResetClosedWindowsCache = false
    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let request = ClientRequest(args: ["enable", "off"], stdin: "", windowId: nil, workspace: nil)
        if throughUi { try await runEnableCommandFromUi(.off) }
        else { _ = try await runSocketCommandSession(parseCommand("enable off").cmdOrDie, request: request, token: .forceRun) }
        return true
    }
}
private struct NestedTrailingFixtureCommand: Command {
    @MainActor static var calls = 0
    let args = EnableCmdArgs(rawArgs: [], targetState: .on)
    let shouldResetClosedWindowsCache = false
    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool { Self.calls += 1; return true }
}

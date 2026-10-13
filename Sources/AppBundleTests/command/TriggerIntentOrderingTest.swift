@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor final class TriggerIntentOrderingTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
        TrayMenuModel.shared.isEnabled = true
        activeMode = mainModeId
        HarmlessTriggerFixtureCommand.calls = 0
    }
    override func tearDown() async throws {
        config.modes = [mainModeId: Mode(bindings: [:])]
        TrayMenuModel.shared.isEnabled = true
        activeMode = mainModeId
        resetFocusCacheForTests()
    }
    func testHarmlessTriggerDoesNotCancelEarlierPendingPause() async throws {
        try await exercisePendingPause(invalid: false)
    }
    func testInvalidTriggerDoesNotCancelEarlierPendingPause() async throws {
        try await exercisePendingPause(invalid: true)
    }
    func testActualNestedEnableOnCanSupersedeEarlierPendingPause() async throws {
        try await exercisePendingPause(invalid: false, nestedEnable: true)
    }
    private func exercisePendingPause(invalid: Bool, nestedEnable: Bool = false) async throws {
        if !invalid {
            let target: any Command = nestedEnable ? parseCommand("enable on").cmdOrDie : HarmlessTriggerFixtureCommand()
            let binding = HotkeyBinding(.option, .x, [target], descriptionWithKeyNotation: "option-x")
            config.modes["fixture"] = Mode(bindings: [binding.descriptionWithKeyCode: binding])
        }
        var queries = 0
        appForTests = TriggerOrderingFixtureApp {
            queries += 1
            if queries > 1 { return nil }
            await Task.yield()
            let result = try await self.socket("trigger-binding option-x --mode fixture")
            XCTAssertEqual(result.exitCode, invalid ? 1 : 0)
            XCTAssertTrue(TrayMenuModel.shared.isEnabled) // Earlier Pause is still in its prelude.
            return nil
        }
        var cancelled = false
        do {
            let result = try await socket("enable off")
            XCTAssertEqual(result.exitCode, 0)
        } catch is CancellationError { cancelled = true }
        XCTAssertEqual(cancelled, nestedEnable)
        XCTAssertEqual(TrayMenuModel.shared.isEnabled, nestedEnable)
        XCTAssertEqual(activeMode, nestedEnable ? mainModeId : nil)
        XCTAssertEqual(queries, 2)
        XCTAssertEqual(HarmlessTriggerFixtureCommand.calls, invalid || nestedEnable ? 0 : 1)
    }
    private func socket(_ text: String) async throws -> ServerAnswer {
        let request = ClientRequest(args: text.split(separator: " ").map(String.init), stdin: "", windowId: nil, workspace: nil)
        return try await runSocketCommandSession(parseCommand(text).cmdOrDie, request: request, token: .forceRun)
    }
}
private struct HarmlessTriggerFixtureCommand: Command {
    @MainActor static var calls = 0
    let args = EnableCmdArgs(rawArgs: [], targetState: .on)
    let shouldResetClosedWindowsCache = false
    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool { Self.calls += 1; return true }
}
private final class TriggerOrderingFixtureApp: AbstractApp {
    let pid: Int32 = 999_401
    let rawAppBundleId: String? = "fixture.trigger-order"
    let name: String? = "Fixture"
    let execPath: String? = nil
    let bundlePath: String? = nil
    private let query: @MainActor () async throws -> Window?
    init(_ query: @MainActor @escaping () async throws -> Window?) { self.query = query }
    @MainActor func getFocusedWindow() async throws -> Window? { try await query() }
}

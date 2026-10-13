@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor final class DynamicBindingSessionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
        TrayMenuModel.shared.isEnabled = true
        activeMode = mainModeId
        BindingTargetFixtureCommand.calls = []
    }
    override func tearDown() async throws {
        config.modes = [mainModeId: Mode(bindings: [:])]
        TrayMenuModel.shared.isEnabled = true
        activeMode = mainModeId
        resetFocusCacheForTests()
    }
    func testBindingRemovedByEarlierFakeReloadDoesNotExecuteOldTarget() async throws {
        installFixtureBinding("old")
        try await runHotkeyCommandSession([FakeReloadBindingFixtureCommand(label: nil), parseCommand("trigger-binding option-x --mode main").cmdOrDie])
        XCTAssertEqual(BindingTargetFixtureCommand.calls, [])
    }
    func testParsedTriggerCanBeReusedAgainstLiveBindings() async throws {
        let trigger = parseCommand("trigger-binding option-x --mode main").cmdOrDie
        installFixtureBinding("old")
        try await runHotkeyCommandSession([trigger])
        installFixtureBinding("new")
        try await runHotkeyCommandSession([trigger])
        XCTAssertEqual(BindingTargetFixtureCommand.calls, ["old", "new"])
        XCTAssertTrue(TrayMenuModel.shared.isEnabled)
        XCTAssertEqual(activeMode, mainModeId)
    }
    func testTriggerReservesIntentEvenWhenQueryChangesNonEnableTargetToEnable() async throws {
        let oldBinding = HotkeyBinding(.option, .x, [BindingTargetFixtureCommand(label: "old")], descriptionWithKeyNotation: "option-x")
        config.modes["fixture"] = Mode(bindings: [oldBinding.descriptionWithKeyCode: oldBinding])
        var queries = 0
        appForTests = DynamicBindingQueryFixtureApp {
            queries += 1
            if queries > 1 { return nil }
            await Task.yield()
            let changed = HotkeyBinding(.option, .x, [parseCommand("enable toggle").cmdOrDie], descriptionWithKeyNotation: "option-x")
            config.modes["fixture"] = Mode(bindings: [changed.descriptionWithKeyCode: changed])
            let request = ClientRequest(args: ["enable", "off"], stdin: "", windowId: nil, workspace: nil)
            _ = try await runSocketCommandSession(parseCommand("enable off").cmdOrDie, request: request, token: .forceRun)
            return nil
        }
        let request = ClientRequest(args: ["trigger-binding", "option-x", "--mode", "fixture"], stdin: "", windowId: nil, workspace: nil)
        do {
            _ = try await runSocketCommandSession(parseCommand("trigger-binding option-x --mode fixture").cmdOrDie, request: request, token: .forceRun)
            XCTFail("Newer Pause must supersede the dynamically enabled binding")
        } catch is CancellationError {}
        XCTAssertEqual(queries, 2)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        XCTAssertEqual(BindingTargetFixtureCommand.calls, [])
    }
    func testTriggerUsesBindingChangedByEarlierFakeReload() async throws {
        installFixtureBinding("old")
        try await runHotkeyCommandSession([FakeReloadBindingFixtureCommand(), parseCommand("trigger-binding option-x --mode main").cmdOrDie])
        XCTAssertEqual(BindingTargetFixtureCommand.calls, ["new"])
    }
    func testPreviouslyMissingBindingIsLookedUpAfterEarlierFakeReload() async throws {
        try await runHotkeyCommandSession([FakeReloadBindingFixtureCommand(), parseCommand("trigger-binding option-x --mode main").cmdOrDie])
        XCTAssertEqual(BindingTargetFixtureCommand.calls, ["new"])
    }
}

@MainActor private func installFixtureBinding(_ label: String) {
    let binding = HotkeyBinding(.option, .x, [BindingTargetFixtureCommand(label: label)], descriptionWithKeyNotation: "option-x")
    config.modes[mainModeId] = Mode(bindings: [binding.descriptionWithKeyCode: binding])
}
private struct FakeReloadBindingFixtureCommand: Command {
    var label: String? = "new"
    let args = EnableCmdArgs(rawArgs: [], targetState: .on)
    let shouldResetClosedWindowsCache = false
    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        if let label { installFixtureBinding(label) }
        else { config.modes[mainModeId] = Mode(bindings: [:]) }
        // In-memory replacement only: no config file, reload, activation or key registration.
        return true
    }
}
private struct BindingTargetFixtureCommand: Command {
    @MainActor static var calls: [String] = []
    let label: String
    let args = EnableCmdArgs(rawArgs: [], targetState: .on)
    let shouldResetClosedWindowsCache = false
    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool { Self.calls.append(label); return true }
}

private final class DynamicBindingQueryFixtureApp: AbstractApp {
    let pid: Int32 = 999_381
    let rawAppBundleId: String? = "fixture.dynamic-binding"
    let name: String? = "Fixture"
    let execPath: String? = nil
    let bundlePath: String? = nil
    private let query: @MainActor () async throws -> Window?
    init(_ query: @MainActor @escaping () async throws -> Window?) { self.query = query }
    @MainActor func getFocusedWindow() async throws -> Window? { try await query() }
}

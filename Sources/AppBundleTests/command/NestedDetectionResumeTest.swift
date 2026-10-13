@testable import AppBundle
import Common
import XCTest

@MainActor final class NestedDetectionResumeTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
        uiResumeFocus.reset()
        DetectionEnableFixtureCommand.calls = 0
        DetectionModeFixtureCommand.focusIds = []
        DetectionModeFixtureCommand.workspaces = []
        DetectionNewPauseFixtureCommand.newer = nil
    }
    override func tearDown() async throws {
        config.onWindowDetected = []
        config.onModeChanged = []
        DetectionNewPauseFixtureCommand.newer = nil
        TrayMenuModel.shared.isEnabled = true
        activeMode = mainModeId
        resetFocusCacheForTests()
        uiResumeFocus.reset()
    }
    func testNestedDetectionEnableStillAdoptsValidatedUnseenWindow() async throws {
        try await exerciseDetectionResume(newerUserPause: false)
    }
    func testNewerUiPauseDuringDetectionStillSupersedesOuterResume() async throws {
        try await exerciseDetectionResume(newerUserPause: true)
    }
    func testNestedModeCallbackSessionDoesNotRestoreStaleFocusAfterRegistrationGraceExpires() async throws {
        try await exerciseDetectionResume(newerUserPause: false, modeCallbacks: true)
    }
    func testNewerPauseStillWinsWithNestedModeCallbackSession() async throws {
        try await exerciseDetectionResume(newerUserPause: true, modeCallbacks: true)
    }
    func testMoveOnlyDetectionRuleFinalAdoptionFollowsCandidateToB() async throws {
        try await exerciseDetectionResume(newerUserPause: false, move: true)
    }
    func testMoveThenNestedEnableModeSessionFollowsCandidateToB() async throws {
        try await exerciseDetectionResume(newerUserPause: false, modeCallbacks: true, move: true)
    }
    func testNewerPauseStillWinsAfterMoveOnlyDetectionRule() async throws {
        try await exerciseDetectionResume(newerUserPause: true, move: true)
    }
    func testNewerSameAppFocusDuringMovedCandidateModeQueryIsPreserved() async throws {
        try await exerciseDetectionResume(newerUserPause: false, modeCallbacks: true, move: true, changeDuringModeQuery: true)
    }
    private func exerciseDetectionResume(newerUserPause: Bool, modeCallbacks: Bool = false, move: Bool = false, changeDuringModeQuery: Bool = false) async throws {
        let old = TestWindow.new(id: 391, parent: Workspace.get(byName: "old").rootTilingContainer)
        let newer = TestWindow.new(id: 392, parent: Workspace.get(byName: "newer").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        appForTests = nil
        var registered: TestWindow?
        var cachePrimed = false
        var now = ContinuousClock().now
        let clock = FocusStealingPreventionState(now: { now })
        clock.markUserInitiatedFocusChange()
        if modeCallbacks {
            config.preventFocusStealing = .always
            config.onModeChanged = [DetectionModeFixtureCommand()]
        }
        var commands: [any Command] = []
        if move { commands.append(parseCommand("move-node-to-workspace B").cmdOrDie) }
        if !move || modeCallbacks { commands.append(DetectionEnableFixtureCommand()) }
        if newerUserPause {
            DetectionNewPauseFixtureCommand.newer = newer
            commands.append(DetectionNewPauseFixtureCommand())
        }
        config.onWindowDetected = [WindowDetectedCallback(rawRun: commands)]
        uiResumeFocus.rememberCandidate {
            UiResumeFocusCandidate(isStillFocused: {
                registered == nil || TestApp.shared.focusedWindow === registered
            }, resolveWithWindowAdmission: { validate, admit in
                try await registerFocusedWindowWithAxCache(
                    expectedWindowId: 393,
                    registerAxWindow: { cachePrimed = true; return 393 },
                    beforeModelRegistration: validate,
                    registerModelWindow: { id in
                        XCTAssertTrue(cachePrimed)
                        let selected = TestWindow.new(id: id, parent: Workspace.get(byName: move ? "old" : "selected").rootTilingContainer)
                        registered = selected
                        selected.nativeFocus() // Synthetic native identity exists independently of modeled focus.
                        if modeCallbacks {
                            await Task.yield()
                            now = now.advanced(by: .seconds(2))
                            XCTAssertFalse(clock.isUserInitiatedFocusChange)
                            resetFocusStealingPreventionForTests()
                        }
                        if changeDuringModeQuery {
                            appForTests = DetectionModeQueryFixtureApp {
                                await Task.yield()
                                newer.nativeFocus()
                                return newer
                            }
                        }
                        try await tryOnWindowDetected(selected, beforeCallbacks: { try await admit(selected) })
                        return selected
                    },
                )
            })
        }
        if changeDuringModeQuery {
            do { try await runEnableCommandFromUi(.on); XCTFail("Changed focus must abort before mode sync applies") }
            catch UiResumeFocusError.focusKeptChanging {}
            XCTAssertTrue(TestApp.shared.focusedWindow === newer)
            XCTAssertEqual(DetectionModeFixtureCommand.focusIds, [])
            XCTAssertEqual(registered?.nodeWorkspace?.name, "B")
            return
        }
        try await runEnableCommandFromUi(.on)
        XCTAssertEqual(DetectionEnableFixtureCommand.calls, !move || modeCallbacks ? 1 : 0)
        XCTAssertNotNil(registered)
        if modeCallbacks {
            XCTAssertEqual(DetectionModeFixtureCommand.focusIds, [393])
            if move { XCTAssertEqual(DetectionModeFixtureCommand.workspaces, ["B"]) }
        }
        if move { XCTAssertEqual(registered?.nodeWorkspace?.name, "B") }
        if newerUserPause {
            XCTAssertFalse(TrayMenuModel.shared.isEnabled)
            XCTAssertTrue(focus.windowOrNil === newer)
            XCTAssertTrue(TestApp.shared.focusedWindow === newer)
        } else {
            XCTAssertTrue(TrayMenuModel.shared.isEnabled)
            XCTAssertEqual(activeMode, mainModeId)
            XCTAssertTrue(focus.windowOrNil === registered)
            XCTAssertTrue(registered?.nodeWorkspace?.isVisible == true)
            XCTAssertTrue(TestApp.shared.focusedWindow === registered)
        }
    }
}

/// Fake detection action: invokes only the synthetic test command/mode state, never real keys or AX.
private struct DetectionEnableFixtureCommand: Command {
    @MainActor static var calls = 0
    let args = EnableCmdArgs(rawArgs: [], targetState: .on)
    let shouldResetClosedWindowsCache = false
    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        Self.calls += 1
        return try await EnableCommand(args: args).run(env, io)
    }
}
private struct DetectionNewPauseFixtureCommand: Command {
    @MainActor static var newer: Window?
    let args = EnableCmdArgs(rawArgs: [], targetState: .off)
    let shouldResetClosedWindowsCache = false
    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        Self.newer?.nativeFocus()
        try await runEnableCommandFromUi(.off)
        return true
    }
}

/// Only observes in-memory modeled focus; never launches, registers keys or calls AX.
private struct DetectionModeFixtureCommand: Command {
    @MainActor static var focusIds: [UInt32] = []
    @MainActor static var workspaces: [String] = []
    let args = EnableCmdArgs(rawArgs: [], targetState: .on)
    let shouldResetClosedWindowsCache = false
    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        if let id = focus.windowOrNil?.windowId { Self.focusIds.append(id) }
        Self.workspaces.append(focus.workspace.name)
        return true
    }
}

private final class DetectionModeQueryFixtureApp: AbstractApp {
    let pid: Int32 = 999_411
    let rawAppBundleId: String? = "fixture.detection-mode-query"
    let name: String? = "Fixture"
    let execPath: String? = nil
    let bundlePath: String? = nil
    private let query: @MainActor () async throws -> Window?
    init(_ query: @MainActor @escaping () async throws -> Window?) { self.query = query }
    @MainActor func getFocusedWindow() async throws -> Window? { try await query() }
}

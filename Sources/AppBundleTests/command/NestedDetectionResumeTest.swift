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
    private func exerciseDetectionResume(newerUserPause: Bool, modeCallbacks: Bool = false) async throws {
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
        var commands: [any Command] = [DetectionEnableFixtureCommand()]
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
                        let selected = TestWindow.new(id: id, parent: Workspace.get(byName: "selected").rootTilingContainer)
                        registered = selected
                        selected.nativeFocus() // Synthetic native identity exists independently of modeled focus.
                        if modeCallbacks {
                            await Task.yield()
                            now = now.advanced(by: .seconds(2))
                            XCTAssertFalse(clock.isUserInitiatedFocusChange)
                            resetFocusStealingPreventionForTests()
                        }
                        try await tryOnWindowDetected(selected, beforeCallbacks: { try await admit(selected) })
                        return selected
                    },
                )
            })
        }
        try await runEnableCommandFromUi(.on)
        XCTAssertEqual(DetectionEnableFixtureCommand.calls, 1)
        XCTAssertNotNil(registered)
        if modeCallbacks { XCTAssertEqual(DetectionModeFixtureCommand.focusIds, [393]) }
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
    let args = EnableCmdArgs(rawArgs: [], targetState: .on)
    let shouldResetClosedWindowsCache = false
    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        if let id = focus.windowOrNil?.windowId { Self.focusIds.append(id) }
        return true
    }
}

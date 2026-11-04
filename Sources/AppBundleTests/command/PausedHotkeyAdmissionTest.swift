@testable import AppBundle
import Common
import Foundation
import XCTest

@MainActor
final class PausedHotkeyAdmissionTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
        config.preventFocusStealing = .always
        sessionCoordinator.setEnabled(true)
        activeMode = mainModeId
        appForTests = TestApp.shared
        resetFocusCacheForTests()
        uiResumeFocus.reset()
        resetFocusStealingPreventionForTests()
    }

    override func tearDown() async throws {
        resetFocusCacheForTests()
        uiResumeFocus.reset()
        resetFocusStealingPreventionForTests()
        sessionCoordinator.setEnabled(true)
        activeMode = mainModeId
        appForTests = TestApp.shared
    }

    func testPausedResumeKeepsCurrentNativeWindowAfterGraceExpiresDuringQuery() async throws {
        defer { resetFocusCacheForTests() }
        let old = TestWindow.new(id: 951, parent: Workspace.get(byName: "old").rootTilingContainer)
        let external = TestWindow.new(id: 952, parent: Workspace.get(byName: "external").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        old.nativeFocus()
        _ = updateFocusCache(old)
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        external.nativeFocus()
        markUserInitiatedFocusChange() // The real key-down handler does this before dispatch.
        appForTests = PausedHotkeyReviewApp {
            await Task.yield()
            // Model expiration of the one-second input grace while an AX request is suspended.
            resetFocusStealingPreventionForTests()
            return external
        }
        try await runHotkeyCommandSession([parseCommand("enable on").cmdOrDie])
        XCTAssertTrue(sessionCoordinator.isEnabled)
        XCTAssertTrue(focus.windowOrNil === external, "Resume should adopt the paused user's current window")
        XCTAssertTrue(TestApp.shared.focusedWindow === external, "The focus prelude must not reactivate stale focus")
    }

    func testToggleRoundTripWithEmptyRegistrationTables() async throws {
        defer { resetFocusCacheForTests() }
        try await runHotkeyCommandSession([parseCommand("enable toggle").cmdOrDie])
        XCTAssertFalse(sessionCoordinator.isEnabled)
        XCTAssertNil(activeMode)
        try await runHotkeyCommandSession([parseCommand("enable toggle").cmdOrDie])
        XCTAssertTrue(sessionCoordinator.isEnabled)
        XCTAssertEqual(activeMode, mainModeId)
    }

    func testResumeModeCallbackCanIntentionallyPause() async throws {
        defer { resetFocusCacheForTests() }
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        config.onModeChanged = [parseCommand("enable off").cmdOrDie]
        try await runHotkeyCommandSession([parseCommand("enable on").cmdOrDie])
        XCTAssertFalse(sessionCoordinator.isEnabled)
        XCTAssertNil(activeMode)
    }

    func testPausedOrdinaryAndMixedHotkeysRemainInert() async throws {
        defer { resetFocusCacheForTests() }
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let previous = focus.workspace
        try await runHotkeyCommandSession([parseCommand("workspace changed").cmdOrDie])
        try await runHotkeyCommandSession([parseCommand("enable on").cmdOrDie, parseCommand("workspace changed").cmdOrDie])
        XCTAssertFalse(sessionCoordinator.isEnabled)
        XCTAssertTrue(focus.workspace === previous)
    }

    func testPausedBindingFeatureFlagMatrixWithoutRegisteringKeys() {
        let enable = HotkeyBinding(.option, .e, [parseCommand("enable toggle").cmdOrDie])
        config.modes[mainModeId] = Mode(bindings: [enable.descriptionWithKeyCode: enable])
        sessionCoordinator.setEnabled(false)
        for management in [false, true] {
            for appSwitching in [false, true] {
                for shortcuts in [false, true] {
                    config.enableWindowManagement = management
                    config.enableWorkspaceAppSwitching = appSwitching
                    config.enableKeyboardShortcuts = shortcuts
                    XCTAssertEqual(hotkeyBindings(for: "other").count, shortcuts ? 1 : 0)
                }
            }
        }
    }

    func testPauseThenModeStillRegistersAndDispatchesOnlyMainResumeBindings() async throws {
        defer { resetFocusCacheForTests() }
        config.modes["other"] = Mode(bindings: [:])
        try await runHotkeyCommandSession([parseCommand("enable off").cmdOrDie, parseCommand("mode other").cmdOrDie])
        XCTAssertFalse(sessionCoordinator.isEnabled)
        XCTAssertEqual(activeMode, "other") // Preserve intentional sequential mode commands.
        let main = HotkeyBinding(.option, .e, [parseCommand("enable toggle").cmdOrDie])
        let other = HotkeyBinding(.option, .w, [parseCommand("workspace other").cmdOrDie])
        let otherEnable = HotkeyBinding(.option, .o, [parseCommand("enable on").cmdOrDie])
        config.modes[mainModeId] = Mode(bindings: [main.descriptionWithKeyCode: main])
        config.modes["other"] = Mode(bindings: [other.descriptionWithKeyCode: other, otherEnable.descriptionWithKeyCode: otherEnable])
        XCTAssertEqual(hotkeyBindings(for: activeMode), [main.descriptionWithKeyCode: main])
        XCTAssertEqual(hotkeyDispatchMode, mainModeId)
        sessionCoordinator.setEnabled(true)
        XCTAssertEqual(hotkeyBindings(for: activeMode), config.modes["other"]?.bindings)
        XCTAssertEqual(hotkeyDispatchMode, "other")
    }

    func testResumeCallbackMayEnterAnotherEnabledMode() async throws {
        defer { resetFocusCacheForTests() }
        config.modes["other"] = Mode(bindings: [:])
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        config.onModeChanged = [parseCommand("mode other").cmdOrDie]
        try await runHotkeyCommandSession([parseCommand("enable on").cmdOrDie])
        XCTAssertTrue(sessionCoordinator.isEnabled)
        XCTAssertEqual(activeMode, "other")
    }

    func testPausedOffNoopDoesNotQueryOrRestoreStaleFocus() async throws {
        defer { resetFocusCacheForTests() }
        let old = TestWindow.new(id: 961, parent: Workspace.get(byName: "old").rootTilingContainer)
        let external = TestWindow.new(id: 962, parent: Workspace.get(byName: "external").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        external.nativeFocus()
        var queries = 0
        appForTests = PausedHotkeyReviewApp { queries += 1; return external }
        try await runHotkeyCommandSession([parseCommand("enable off --fail-if-noop").cmdOrDie])
        XCTAssertFalse(sessionCoordinator.isEnabled)
        XCTAssertEqual(queries, 0)
        XCTAssertTrue(TestApp.shared.focusedWindow === external)
        XCTAssertTrue(focus.windowOrNil === old)
    }

    func testPausedEnableSequenceRetainsSequentialSemanticsAndParsedCommands() async throws {
        defer { resetFocusCacheForTests() }
        let commands = ["enable off --fail-if-noop", "enable toggle", "enable toggle", "enable on"].map { parseCommand($0).cmdOrDie }
        for _ in 0 ..< 2 {
            _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
            try await runHotkeyCommandSession(commands)
            XCTAssertTrue(sessionCoordinator.isEnabled)
            XCTAssertEqual(activeMode, mainModeId)
            for command in commands { XCTAssertNil((command as? EnableCommand)?.requestedIntent) }
            resetFocusCacheForTests()
        }
    }

    func testLaterPauseDuringCandidateQueryStopsEntireEnableSequence() async throws {
        defer { resetFocusCacheForTests() }
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        appForTests = nil
        var queries = 0
        uiResumeFocus.rememberCandidate {
            queries += 1
            try await runEnableCommandFromUi(.off)
            return nil
        }
        try await runHotkeyCommandSession([parseCommand("enable on").cmdOrDie, parseCommand("enable on").cmdOrDie])
        XCTAssertEqual(queries, 1)
        XCTAssertFalse(sessionCoordinator.isEnabled)
        XCTAssertNil(activeMode)
    }

    func testUnavailableCandidateRejectsResumeBeforeEnabling() async throws {
        defer { resetFocusCacheForTests() }
        let old = TestWindow.new(id: 971, parent: Workspace.get(byName: "old").rootTilingContainer)
        let external = TestWindow.new(id: 972, parent: Workspace.get(byName: "external").rootTilingContainer)
        XCTAssertTrue(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        appForTests = nil
        uiResumeFocus.rememberCandidate {
            UiResumeFocusCandidate(resolve: { external.unbindFromParent(); return external })
        }
        do {
            try await runHotkeyCommandSession([parseCommand("enable on").cmdOrDie])
            XCTFail("An unavailable selection must not enable using old modeled focus")
        } catch UiResumeFocusError.selectedWindowUnavailable {}
        XCTAssertFalse(sessionCoordinator.isEnabled)
        XCTAssertTrue(focus.windowOrNil === old)
    }

    func testReloadPreservesPauseWithAllPhysicalKeysDisabled() async throws {
        try await exercisePausedReload(modeAfterPause: nil)
    }

    func testReloadAfterPausedModeChangeStillUsesMainResumeBindings() async throws {
        try await exercisePausedReload(modeAfterPause: "other")
    }

    private func exercisePausedReload(modeAfterPause: String?) async throws {
        defer { resetFocusCacheForTests() }
        let url = FileManager.default.temporaryDirectory.appending(path: "airlock-pr125-review-" + UUID().uuidString + ".toml")
        defer { try? FileManager.default.removeItem(at: url) }
        try """
            enable-window-management = false
            enable-workspace-app-switching = false
            enable-keyboard-shortcuts = false
            auto-reload-config = false
            [quick-switcher]
            enabled = false
            [mode.main.binding]
            option-e = 'enable toggle'
            [mode.other.binding]
            option-o = 'enable on'
            """.write(to: url, atomically: true, encoding: .utf8)
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        if let modeAfterPause {
            config.modes[modeAfterPause] = Mode(bindings: [:])
            _ = try await parseCommand("mode \(modeAfterPause)").cmdOrDie.run(.defaultEnv, .emptyStdin)
        }
        if case .failure(let message) = readConfig(forceConfigUrl: url) { XCTFail(message); return }
        let reloaded = try await reloadConfig(forceConfigUrl: url)
        XCTAssertTrue(reloaded)
        XCTAssertFalse(sessionCoordinator.isEnabled)
        XCTAssertEqual(activeMode, modeAfterPause)
        XCTAssertEqual(hotkeyDispatchMode, mainModeId)
        XCTAssertFalse(config.enableKeyboardShortcuts)
        XCTAssertEqual(pausedBindings().count, 1)
        XCTAssertTrue(hotkeyBindings(for: activeMode).isEmpty)
        // Inspect the enabled-shortcuts selection without registering physical keys.
        config.enableKeyboardShortcuts = true
        XCTAssertEqual(hotkeyBindings(for: activeMode), pausedBindings())
    }
}

private final class PausedHotkeyReviewApp: AbstractApp {
    let pid: Int32 = 999_951
    let rawAppBundleId: String? = "fixture.paused-hotkey-review"
    let name: String? = "Fixture"
    let execPath: String? = nil
    let bundlePath: String? = nil
    private let query: @MainActor () async throws -> Window?
    init(_ query: @MainActor @escaping () async throws -> Window?) { self.query = query }
    @MainActor func getFocusedWindow() async throws -> Window? { try await query() }
}

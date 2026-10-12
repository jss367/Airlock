@testable import AppBundle
import Common
import XCTest

@MainActor
final class EnableCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
        uiResumeFocus.reset()
    }

    override func tearDown() async throws {
        TrayMenuModel.shared.isEnabled = true
        resetFocusCacheForTests() // Also cancels the refresh the session scheduled
        uiResumeFocus.reset()
    }

    /// Pause on workspace "a" with window 1 focused, then work in window 2 on workspace "b", which is
    /// visible because Airlock is paused. Resuming from the menu must follow the user to window 2,
    /// not push focus back to window 1 and hide workspace "b".
    func testResumeFromUiFollowsTheWindowFocusedWhilePaused() async throws {
        config.preventFocusStealing = .crossWorkspace
        let beforePause = TestWindow.new(id: 1, parent: Workspace.get(byName: "a").rootTilingContainer)
        let whilePaused = TestWindow.new(id: 2, parent: Workspace.get(byName: "b").rootTilingContainer)
        check(beforePause.focusWindow())
        beforePause.nativeFocus()
        _ = updateFocusCache(beforePause)
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)

        // Nothing records focus while paused
        whilePaused.nativeFocus()
        try await runEnableCommandFromUi(.toggle)
        focusEvents.cancelRefresh()

        assertTrue(TrayMenuModel.shared.isEnabled)
        assertTrue(focus.windowOrNil === whilePaused)
        assertEquals(focus.workspace.name, "b")
        assertTrue(TestApp.shared.focusedWindow === whilePaused)
    }

    func testResumeFromSettingsFollowsLastExternalWindowAcrossRepeatedResumes() async throws {
        config.preventFocusStealing = .always
        let beforePause = TestWindow.new(id: 1, parent: Workspace.get(byName: "before").rootTilingContainer)
        check(beforePause.focusWindow())
        beforePause.nativeFocus()
        _ = updateFocusCache(beforePause)
        for id in 2 ... 4 {
            let external = TestWindow.new(id: UInt32(id), parent: Workspace.get(byName: "external\(id)").rootTilingContainer)
            _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
            external.nativeFocus()
            uiResumeFocus.remember { external }
            appForTests = nil // Airlock's own frontmost settings app is excluded from native focus.
            try await runEnableCommandFromUi(.on)
            resetFocusCacheForTests()
            assertTrue(focus.windowOrNil === external)
            assertTrue(external.nodeWorkspace?.isVisible == true)
            assertEquals(focus.workspace.name, "external\(id)")
            try await runEnableCommandFromUi(.on) // Repeated resume is a no-op.
            resetFocusCacheForTests()
            assertTrue(focus.windowOrNil === external)
        }
    }

    func testResumeDiscardsRememberedAppChangedDuringQuery() async throws {
        let state = UiResumeFocusState()
        let old = TestWindow.new(id: 1, parent: Workspace.get(byName: "old").rootTilingContainer)
        let latest = TestWindow.new(id: 2, parent: Workspace.get(byName: "latest").rootTilingContainer)
        state.remember {
            await Task.yield()
            state.remember { latest }
            return old
        }
        let result = try await state.windowToResume(nativeFocus: { nil })
        assertTrue(result === latest)
    }

    func testResumePrefersNativeFocusChangedDuringRememberedQuery() async throws {
        let state = UiResumeFocusState()
        let old = TestWindow.new(id: 1, parent: Workspace.get(byName: "old").rootTilingContainer)
        let latest = TestWindow.new(id: 2, parent: Workspace.get(byName: "latest").rootTilingContainer)
        var native: Window?
        state.remember {
            await Task.yield()
            native = latest
            return old
        }
        let result = try await state.windowToResume(nativeFocus: { native })
        assertTrue(result === latest)
    }

    func testResumeDoesNotRebindWindowClosedDuringQuery() async throws {
        let state = UiResumeFocusState()
        let closed = TestWindow.new(id: 1, parent: Workspace.get(byName: "closed").rootTilingContainer)
        state.remember {
            closed.closeAxWindow()
            return closed
        }
        let result = try await state.windowToResume(nativeFocus: { nil })
        XCTAssertNil(result)
        XCTAssertFalse(closed.isBound)
    }

    func testInterruptedResumeDoesNotOverrideAnAlreadyCompletedResume() async throws {
        let old = TestWindow.new(id: 1, parent: Workspace.get(byName: "old").rootTilingContainer)
        let stale = TestWindow.new(id: 2, parent: Workspace.get(byName: "stale").rootTilingContainer)
        let newer = TestWindow.new(id: 3, parent: Workspace.get(byName: "newer").rootTilingContainer)
        check(old.focusWindow())
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        appForTests = nil
        uiResumeFocus.remember {
            await Task.yield()
            // A later action completed while the earlier resume was querying the old external app.
            TrayMenuModel.shared.isEnabled = true
            check(newer.focusWindow())
            return stale
        }
        try await runEnableCommandFromUi(.on)
        resetFocusCacheForTests()
        assertTrue(focus.windowOrNil === newer)
        assertTrue(TrayMenuModel.shared.isEnabled)
    }

    func testContinuousFocusChangesAbortResumeAndKeepAirlockPaused() async throws {
        let old = TestWindow.new(id: 1, parent: Workspace.get(byName: "old").rootTilingContainer)
        let external = TestWindow.new(id: 2, parent: Workspace.get(byName: "external").rootTilingContainer)
        check(old.focusWindow())
        old.nativeFocus()
        _ = updateFocusCache(old)
        _ = try await parseCommand("enable off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        external.nativeFocus()
        appForTests = nil
        var queries = 0
        @MainActor func changingFocus() async throws -> Window? {
            queries += 1
            await Task.yield()
            uiResumeFocus.remember(changingFocus)
            return external
        }
        uiResumeFocus.remember(changingFocus)

        do {
            try await runEnableCommandFromUi(.on)
            XCTFail("Continuous focus changes must not enable Airlock")
        } catch UiResumeFocusError.focusKeptChanging {}

        XCTAssertEqual(queries, 3)
        XCTAssertFalse(TrayMenuModel.shared.isEnabled)
        assertTrue(focus.windowOrNil === old)
        assertTrue(TestApp.shared.focusedWindow === external)
        XCTAssertFalse(isQuickSwitcherHotkeyRegistered)

        // A later click can resume normally once the external focus stops changing.
        uiResumeFocus.remember { external }
        try await runEnableCommandFromUi(.on)
        resetFocusCacheForTests()
        assertTrue(TrayMenuModel.shared.isEnabled)
        assertTrue(focus.windowOrNil === external)
    }
}

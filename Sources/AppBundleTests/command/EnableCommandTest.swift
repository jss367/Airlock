@testable import AppBundle
import Common
import XCTest

@MainActor
final class EnableCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    override func tearDown() async throws {
        TrayMenuModel.shared.isEnabled = true
        resetFocusCacheForTests() // Also cancels the refresh the session scheduled
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
}

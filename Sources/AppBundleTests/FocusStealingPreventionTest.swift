@testable import AppBundle
import Common
import XCTest

/// `prevent-focus-stealing` decides, for every focus change macOS reports, whether Airlock follows it
/// or pushes focus back. Each test starts with window 1 focused on workspace "focused", window 2 on
/// the same workspace, and window 3 on workspace "other", with macOS already reporting window 1.
@MainActor
final class FocusStealingPreventionTest: XCTestCase {
    private var current: Window!
    private var sameWorkspace: Window!
    private var otherWorkspace: Window!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        let focused = Workspace.get(byName: "focused").rootTilingContainer
        current = TestWindow.new(id: 1, parent: focused)
        sameWorkspace = TestWindow.new(id: 2, parent: focused)
        otherWorkspace = TestWindow.new(id: 3, parent: Workspace.get(byName: "other").rootTilingContainer)
        check(current.focusWindow())
        _ = updateFocusCache(current)
    }

    func testDecisionForEachModeAndGraceWindow() {
        let rows: [(mode: PreventFocusStealingMode, grace: Bool, target: Window?, allowed: Bool)] = [
            (.off, false, sameWorkspace, true),
            (.off, false, otherWorkspace, true),
            (.crossWorkspace, false, current, true),
            (.crossWorkspace, false, sameWorkspace, true),
            (.crossWorkspace, false, otherWorkspace, false),
            (.crossWorkspace, true, otherWorkspace, true),
            (.crossWorkspace, false, nil, true),
            (.always, false, current, true),
            (.always, false, sameWorkspace, false),
            (.always, false, otherWorkspace, false),
            (.always, true, sameWorkspace, true),
            (.always, true, otherWorkspace, true),
            (.always, false, nil, true),
        ]
        for row in rows {
            config.preventFocusStealing = row.mode
            resetFocusStealingPreventionForTests()
            if row.grace { markUserInitiatedFocusChange() }
            assertEquals(
                shouldAllowFocusChange(to: row.target),
                row.allowed,
                additionalMsg: "mode: \(row.mode), grace: \(row.grace), target: \(row.target?.windowId.description ?? "nil")",
            )
        }
    }

    /// With nothing focused there is no window to protect, but `cross-workspace` still protects the
    /// workspace.
    func testDecisionFromAnEmptyWorkspace() {
        check(Workspace.get(byName: "empty").focusWorkspace())
        config.preventFocusStealing = .always
        assertTrue(shouldAllowFocusChange(to: otherWorkspace))
        config.preventFocusStealing = .crossWorkspace
        assertEquals(shouldAllowFocusChange(to: otherWorkspace), false)
    }

    /// An app activating itself is what `prevent-focus-stealing` exists to stop. The activation
    /// marker only tells space changes apart and must never count as the user asking for focus.
    func testAppActivationDoesNotOpenTheGraceWindow() {
        markRecentAppActivation()
        assertTrue(hadRecentAppActivation)
        assertEquals(isUserInitiatedFocusChange, false)
        assertEquals(shouldAllowFocusChange(to: otherWorkspace), false)
    }

    func testAllowedChangeIsAdopted() {
        assertTrue(updateFocusCache(sameWorkspace))
        assertTrue(focus.windowOrNil === sameWorkspace)
    }

    func testUnchangedNativeFocusIsNotASync() {
        config.preventFocusStealing = .always
        assertEquals(updateFocusCache(current), false)
        assertTrue(focus.windowOrNil === current)
    }

    func testCrossWorkspaceStealIsPushedBack() {
        assertEquals(updateFocusCache(otherWorkspace), false)
        assertTrue(focus.windowOrNil === current)
        assertEquals(focus.workspace.name, "focused")
        assertTrue(TestApp.shared.focusedWindow === current)
    }

    func testAlwaysModePushesBackASameWorkspaceSteal() {
        config.preventFocusStealing = .always
        assertEquals(updateFocusCache(sameWorkspace), false)
        assertTrue(focus.windowOrNil === current)
        assertTrue(TestApp.shared.focusedWindow === current)
    }

    func testOffModeFollowsMacOs() {
        config.preventFocusStealing = .off
        assertTrue(updateFocusCache(otherWorkspace))
        assertTrue(focus.windowOrNil === otherWorkspace)
        assertEquals(focus.workspace.name, "other")
    }

    func testGraceWindowLetsTheUserCrossWorkspaces() {
        markUserInitiatedFocusChange()
        assertTrue(updateFocusCache(otherWorkspace))
        assertTrue(focus.windowOrNil === otherWorkspace)
        assertEquals(focus.workspace.name, "other")
    }

    /// An app that keeps grabbing focus gets pushed back every time, not only the first.
    func testRepeatedStealIsPushedBackEachTime() {
        assertEquals(updateFocusCache(otherWorkspace), false)
        TestApp.shared.focusedWindow = otherWorkspace
        assertEquals(updateFocusCache(otherWorkspace), false)
        assertTrue(TestApp.shared.focusedWindow === current)
        assertTrue(focus.windowOrNil === current)
    }

    /// A blocked steal must not be remembered as the window macOS last focused. Otherwise, when the
    /// user then picks that window on purpose, the change looks like no change and Airlock never
    /// follows it.
    func testUserCanPickAWindowWhoseStealWasBlocked() {
        assertEquals(updateFocusCache(otherWorkspace), false)
        markUserInitiatedFocusChange()
        assertTrue(updateFocusCache(otherWorkspace))
        assertTrue(focus.windowOrNil === otherWorkspace)
    }
}

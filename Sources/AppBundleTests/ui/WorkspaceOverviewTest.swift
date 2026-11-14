@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class WorkspaceOverviewTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    override func tearDown() async throws {
        dismissMissionControl(restoreFocus: false)
    }

    // MARK: Command

    func testMissionControlStaysAnAliasOfWorkspaceOverview() {
        assertTrue(parseCommand("workspace-overview").cmdOrNil is WorkspaceOverviewCommand)
        assertTrue(parseCommand("mission-control").cmdOrNil is WorkspaceOverviewCommand)
        assertEquals(parseCommand("mission-control").cmdOrDie.args.description, "workspace-overview")
    }

    // MARK: Opening

    func testOpensWithoutWaitingForThumbnails() {
        toggleMissionControl()
        assertEquals(isMissionControlOpen, true)
        toggleMissionControl()
        assertEquals(isMissionControlOpen, false)
    }

    func testShortcutThatClosedTheOverviewDoesNotReopenIt() {
        toggleMissionControl()
        dismissWorkspaceOverviewFromShortcut()
        assertEquals(isMissionControlOpen, false)

        // The same key press arriving as the registered hotkey
        toggleMissionControl()
        assertEquals(isMissionControlOpen, false)

        // The next press opens it again
        toggleMissionControl()
        assertEquals(isMissionControlOpen, true)
    }

    // MARK: Workspace list

    func testEmptyWorkspacesAreLeftOutExceptTheFocusedOne() {
        let state = WorkspaceOverviewState(workspaces: [
            workspace("1", windows: [10]),
            workspace("2", windows: []),
            workspace("3", windows: [], isFocused: true),
            workspace("4", windows: []),
            workspace("5", windows: [50]),
        ])
        assertEquals(state.workspaces.map(\.name), ["1", "3", "5"])
        assertEquals(state.selectedWorkspace?.name, "3")
        assertEquals(state.selectedTarget, .workspace("3"))
    }

    func testThumbnailsLoadFromTheSelectedWorkspaceOnward() {
        let state = WorkspaceOverviewState(workspaces: [
            workspace("1", windows: [10, 11]),
            workspace("2", windows: [20], isFocused: true),
            workspace("3", windows: [30]),
        ])
        assertEquals(state.windowIdsFromSelectedWorkspace, [20, 30, 10, 11])
    }

    // MARK: Keyboard

    func testLeftAndRightMoveAcrossWorkspacesAndStopAtTheEnds() {
        let state = WorkspaceOverviewState(workspaces: [
            workspace("1", windows: [10]),
            workspace("2", windows: [20], isFocused: true),
            workspace("3", windows: [30]),
        ])
        state.move(.right)
        state.move(.right)
        assertEquals(state.selectedTarget, .workspace("3"))
        state.move(.left)
        state.move(.left)
        state.move(.left)
        assertEquals(state.selectedTarget, .workspace("1"))
        // Up has nowhere to go from the workspace bar
        state.move(.up)
        assertEquals(state.selectedTarget, .workspace("1"))
    }

    func testDownMovesIntoTheWindowsAndUpComesBack() {
        let state = WorkspaceOverviewState(
            workspaces: [workspace("1", windows: [10, 11, 12, 13, 14], isFocused: true)],
            gridColumns: 3,
        )
        state.move(.down)
        assertEquals(state.selectedTarget, .window(10))
        state.move(.right)
        state.move(.right)
        state.move(.right)
        assertEquals(state.selectedTarget, .window(13)) // wraps onto the next row
        state.move(.left)
        assertEquals(state.selectedTarget, .window(12))
        // Nothing is below the third column, so Down lands on the last window
        state.move(.down)
        assertEquals(state.selectedTarget, .window(14))
        state.move(.down)
        assertEquals(state.selectedTarget, .window(14))
        state.move(.right)
        assertEquals(state.selectedTarget, .window(14))
        state.move(.up)
        assertEquals(state.selectedTarget, .window(11))
        state.move(.up)
        assertEquals(state.selectedTarget, .workspace("1"))
    }

    func testDownStaysOnTheBarOfAnEmptyWorkspace() {
        let state = WorkspaceOverviewState(workspaces: [workspace("1", windows: [], isFocused: true)])
        state.move(.down)
        state.cycleWindow(offset: 1)
        assertEquals(state.selectedTarget, .workspace("1"))
    }

    func testTabCyclesThroughTheSelectedWorkspacesWindows() {
        let state = WorkspaceOverviewState(workspaces: [
            workspace("1", windows: [10, 11, 12], isFocused: true),
            workspace("2", windows: [20]),
        ])
        state.cycleWindow(offset: 1)
        assertEquals(state.selectedTarget, .window(10))
        state.cycleWindow(offset: -1)
        assertEquals(state.selectedTarget, .window(12))
        state.cycleWindow(offset: 1)
        assertEquals(state.selectedTarget, .window(10))

        // Shift+Tab from the workspace bar starts at the last window
        state.move(.up)
        state.cycleWindow(offset: -1)
        assertEquals(state.selectedTarget, .window(12))
    }

    func testKeyActions() {
        assertEquals(workspaceOverviewKeyAction(keyCode: 123, hasShift: false), .move(.left))
        assertEquals(workspaceOverviewKeyAction(keyCode: 124, hasShift: false), .move(.right))
        assertEquals(workspaceOverviewKeyAction(keyCode: 125, hasShift: false), .move(.down))
        assertEquals(workspaceOverviewKeyAction(keyCode: 126, hasShift: false), .move(.up))
        assertEquals(workspaceOverviewKeyAction(keyCode: 48, hasShift: false), .cycleWindow(offset: 1))
        assertEquals(workspaceOverviewKeyAction(keyCode: 48, hasShift: true), .cycleWindow(offset: -1))
        assertEquals(workspaceOverviewKeyAction(keyCode: 36, hasShift: false), .activate)
        assertEquals(workspaceOverviewKeyAction(keyCode: 53, hasShift: false), .close)
        assertNil(workspaceOverviewKeyAction(keyCode: 0, hasShift: false)) // a
    }

    func testConfiguredShortcutIsReadFromEveryMode() {
        let overview = HotkeyBinding(.option, .o, [parseCommand("workspace-overview").cmdOrDie])
        let alias = HotkeyBinding([.control, .option, .shift, .command], .a, [parseCommand("mission-control").cmdOrDie])
        let other = HotkeyBinding(.option, .w, [parseCommand("workspace 1").cmdOrDie])
        config.modes = [
            mainModeId: Mode(bindings: Dictionary(uniqueKeysWithValues: [overview, other].map { ($0.descriptionWithKeyCode, $0) })),
            "service": Mode(bindings: [alias.descriptionWithKeyCode: alias]),
        ]

        assertTrue(isWorkspaceOverviewShortcut(keyCode: 31, modifiers: .option, config)) // o
        // Arrow and function keys carry extra flags that aren't part of the binding
        assertTrue(isWorkspaceOverviewShortcut(keyCode: 31, modifiers: [.option, .numericPad, .function], config))
        assertTrue(isWorkspaceOverviewShortcut(keyCode: 0, modifiers: [.control, .option, .shift, .command], config)) // a
        XCTAssertFalse(isWorkspaceOverviewShortcut(keyCode: 31, modifiers: [.option, .shift], config))
        XCTAssertFalse(isWorkspaceOverviewShortcut(keyCode: 13, modifiers: .option, config)) // w runs another command
        XCTAssertFalse(isWorkspaceOverviewShortcut(keyCode: 0, modifiers: [], config))
    }

    // MARK: Titles and layout

    func testWindowTitleFallsBackToTheAppName() {
        let state = WorkspaceOverviewState(workspaces: [workspace("1", windows: [10, 11], isFocused: true)])
        assertEquals(state.workspaces[0].windows.map(\.displayTitle), ["App 10", "App 11"])

        state.setTitle("Inbox", forWindow: 11)
        assertEquals(state.workspaces[0].windows.map(\.displayTitle), ["App 10", "Inbox"])
    }

    func testGridFitsAsManyTilesAsTheScreenAllows() {
        assertEquals(WorkspaceOverviewLayout.gridColumns(availableWidth: 1728), 6)
        assertEquals(WorkspaceOverviewLayout.tileWidth(availableWidth: 1728, columns: 6), 261)
        // A lone column never grows past the largest tile
        assertEquals(WorkspaceOverviewLayout.gridColumns(availableWidth: 400), 1)
        assertEquals(WorkspaceOverviewLayout.tileWidth(availableWidth: 600, columns: 1), 350)
        assertEquals(WorkspaceOverviewLayout.gridColumns(availableWidth: 0), 1)
    }

    private func workspace(_ name: String, windows: [UInt32], isFocused: Bool = false) -> OverviewWorkspace {
        OverviewWorkspace(
            name: name,
            isFocused: isFocused,
            windows: windows.map { OverviewWindow(id: $0, appName: "App \($0)", title: "", icon: nil) },
        )
    }
}

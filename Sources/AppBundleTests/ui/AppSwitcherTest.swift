@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class AppSwitcherTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testWindowsByFocusRecencyIsGlobalAcrossContainers() {
        let workspace = Workspace.get(byName: name)
        var x1: Window!
        var x2: Window!
        var other: Window!
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                x1 = TestWindow.new(id: 1, parent: $0)
                other = TestWindow.new(id: 3, parent: $0)
            }
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                x2 = TestWindow.new(id: 2, parent: $0)
            }
            TestWindow.new(id: 4, parent: $0) // never focused
        }

        assertTrue(x1.focusWindow())
        assertTrue(x2.focusWindow())
        assertTrue(other.focusWindow())

        // other's container is now the most recent root child, but x2 was focused after x1
        assertEquals(windowsByFocusRecency(workspace).map(\.windowId), [3, 2, 1, 4])
    }

    func testGroupedPreservingOrderKeepsFirstAppearanceOrder() {
        // (pid, windowId), most recently focused window first
        let windows = [(2, 20), (1, 10), (2, 21), (3, 30), (1, 11)]
        let groups = groupedPreservingOrder(windows, by: { $0.0 })

        // The app of the most recent window leads, so Cmd+Tab's second entry is the previous app
        assertEquals(groups.map(\.key), [2, 1, 3])
        assertEquals(groups.map { $0.items.map(\.1) }, [[20, 21], [10, 11], [30]])
    }

    func testThumbnailsLoadFromTheSelectedAppOnward() {
        let state = AppSwitcherState(groups: [group(pid: 1, windows: [10, 11]), group(pid: 2, windows: [20]), group(pid: 3, windows: [30, 31])], selectedAppIndex: 1)
        assertEquals(state.windowIdsFromSelectedApp, [20, 30, 31, 10, 11])

        state.cycleApp(offset: -1)
        assertEquals(state.windowIdsFromSelectedApp, [10, 11, 20, 30, 31])
    }

    func testContentWidthFitsIconsAndTilesWithinTheScreen() {
        // One app with one window: the single thumbnail tile sets the width
        assertEquals(AppSwitcherLayout.contentWidth(appCount: 1, maxWindowCount: 1, availableWidth: 2000), 320)
        // Three windows are wider than three icons
        assertEquals(AppSwitcherLayout.contentWidth(appCount: 3, maxWindowCount: 3, availableWidth: 2000), 688)
        // Beyond four windows the strip scrolls instead of growing
        assertEquals(
            AppSwitcherLayout.contentWidth(appCount: 3, maxWindowCount: 9, availableWidth: 2000),
            AppSwitcherLayout.contentWidth(appCount: 3, maxWindowCount: 4, availableWidth: 2000),
        )
        // Many apps widen the panel, but never past the screen
        assertEquals(AppSwitcherLayout.contentWidth(appCount: 12, maxWindowCount: 1, availableWidth: 2000), 1172)
        assertEquals(AppSwitcherLayout.contentWidth(appCount: 12, maxWindowCount: 1, availableWidth: 900), 900)
    }

    func testHoverWaitsForThePointerToMove() {
        var pointer = CGPoint(x: 100, y: 100)
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 1, pointerLocation: { pointer })

        // The panel opened under a resting pointer: the keyboard's selection stands
        state.hoverApp(at: 2)
        assertEquals(state.selectedAppIndex, 1)

        pointer.x += 10
        state.hoverApp(at: 2)
        assertEquals(state.selectedAppIndex, 2)
        assertEquals(state.selectedWindowIndex, 0)
        assertEquals(state.selectionCameFromKeyboard, false)

        state.hoverWindow(at: 1)
        assertEquals(state.selectedWindowIndex, 1)
    }

    func testKeyboardSelectionHoldsUntilThePointerMovesAgain() {
        var pointer = CGPoint(x: 100, y: 100)
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0, pointerLocation: { pointer })
        pointer.x += 10
        state.hoverApp(at: 2)
        assertEquals(state.selectedAppIndex, 2)

        // The row scrolls under the pointer after a key press, which reports a hover without any movement
        state.cycleApp(offset: 1)
        assertEquals(state.selectedAppIndex, 0)
        assertEquals(state.selectionCameFromKeyboard, true)
        state.hoverApp(at: 2)
        assertEquals(state.selectedAppIndex, 0)

        pointer.y += 10
        state.hoverApp(at: 2)
        assertEquals(state.selectedAppIndex, 2)
    }

    func testClickSelectsWithoutPointerMovement() {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0, pointerLocation: { .zero })
        state.selectApp(at: 2)
        assertEquals(state.selectedAppIndex, 2)
        state.selectWindow(at: 1)
        assertEquals(state.selectedWindowIndex, 1)

        // Out-of-range items are ignored
        state.selectApp(at: 7)
        state.selectWindow(at: 7)
        assertEquals(state.selectedAppIndex, 2)
        assertEquals(state.selectedWindowIndex, 1)
    }

    func testRemovingTheSelectedWindowKeepsASelection() {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 2, pointerLocation: { .zero })
        state.cycleWindow(offset: 1)

        // The last window of an app: selection falls back to the window before it
        assertEquals(state.removeSelectedWindow(), 31)
        assertEquals(state.selectedGroup?.windows.map(\.windowId), [30])
        assertEquals(state.selectedWindowIndex, 0)

        // An app's only window: the app goes too, and selection moves to the last app left
        assertEquals(state.removeSelectedWindow(), 30)
        assertEquals(state.groups.map(\.pid), [1, 2])
        assertEquals(state.selectedAppIndex, 1)
    }

    func testRemovingAppsEmptiesTheList() {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0, pointerLocation: { .zero })
        assertEquals(state.removeSelectedApp(), 1)
        assertEquals(state.selectedGroup?.pid, 2)
        assertEquals(state.removeSelectedApp(), 2)
        assertEquals(state.removeSelectedApp(), 3)
        assertTrue(state.groups.isEmpty)
        assertNil(state.removeSelectedApp())
        assertNil(state.removeSelectedWindow())
    }

    func testFailedQuitKeepsTheLastAppAndSelection() {
        let state = AppSwitcherState(groups: [group(pid: 1, windows: [10, 11])], selectedAppIndex: 0)
        state.cycleWindow(offset: 1)
        assertEquals(state.quitApp(pid: 1, requestQuit: { false }), false)
        assertEquals(state.groups.map(\.pid), [1])
        assertEquals(state.selectedWindowIndex, 1)
        assertEquals(state.quitApp(pid: 1, requestQuit: { true }), true)
        assertTrue(state.groups.isEmpty)
    }

    func testQuitRemovesTheRequestedAppAfterSelectionChanges() {
        let state = AppSwitcherState(groups: threeApps(), selectedAppIndex: 0)
        let target = state.selectedGroup!.pid
        state.cycleApp(offset: 1)
        assertEquals(state.quitApp(pid: target, requestQuit: { true }), true)
        assertEquals(state.groups.map(\.pid), [2, 3])
        assertEquals(state.selectedGroup?.pid, 2)
        var requestedMissingApp = false
        assertEquals(state.quitApp(pid: target, requestQuit: { requestedMissingApp = true; return true }), false)
        assertEquals(requestedMissingApp, false)
    }

    func testRefreshedTitlesApplyToTheCurrentList() async {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        let state = AppSwitcherState(groups: [group(pid: 1, windows: [1, 2])], selectedAppIndex: 0, pointerLocation: { .zero })

        var reported: [UInt32: String] = [:]
        await state.refreshWindowTitles { windowId, title in
            reported[windowId] = title
            // Window 2 is closed from the switcher while titles are still loading
            if windowId == 1 { state.cycleWindow(offset: 1); _ = state.removeSelectedWindow() }
        }

        assertEquals(reported, [1: "TestWindow(1)", 2: "TestWindow(2)"])
        assertEquals(state.groups.first?.windows.map(\.title), ["TestWindow(1)"])
    }

    func testKeyActions() {
        func action(_ keyCode: UInt16, shift: Bool = false, isRepeat: Bool = false) -> AppSwitcherKeyAction? {
            appSwitcherKeyAction(keyCode: keyCode, hasShift: shift, isRepeat: isRepeat)
        }
        assertEquals(action(48), .cycleApp(offset: 1)) // Tab
        assertEquals(action(48, shift: true), .cycleApp(offset: -1))
        assertEquals(action(124), .cycleApp(offset: 1)) // Right
        assertEquals(action(123), .cycleApp(offset: -1)) // Left
        assertEquals(action(125), .cycleWindow(offset: 1)) // Down
        assertEquals(action(126), .cycleWindow(offset: -1)) // Up
        assertEquals(action(38), .cycleWindow(offset: 1)) // j
        assertEquals(action(40), .cycleWindow(offset: -1)) // k
        assertEquals(action(13), .closeWindow) // w
        assertEquals(action(12), .quitApp) // q
        assertEquals(action(53), .cancel) // Escape
        assertNil(action(0)) // a

        // A held key repeats arrows but never closes or quits again
        assertEquals(action(124, isRepeat: true), .cycleApp(offset: 1))
        assertEquals(action(13, isRepeat: true), .ignore)
        assertEquals(action(12, isRepeat: true), .ignore)
    }

    private func threeApps() -> [AppGroup] {
        [group(pid: 1, windows: [10, 11]), group(pid: 2, windows: [20]), group(pid: 3, windows: [30, 31])]
    }

    private func group(pid: Int32, windows: [UInt32]) -> AppGroup {
        AppGroup(
            id: pid,
            pid: pid,
            name: "App \(pid)",
            icon: NSImage(),
            windows: windows.map { AppGroupWindow(id: $0, windowId: $0, title: "Window \($0)") },
        )
    }
}

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

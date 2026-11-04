@testable import AppBundle
import Common
import XCTest

@MainActor
final class MonitorRearrangementTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testEachOldScreenKeepsItsNearestNewScreen() {
        let mapping = mapNewScreensToOldScreens(
            oldScreens: [CGPoint(x: 0, y: 0), CGPoint(x: 1920, y: 0)],
            newScreens: [CGPoint(x: 0, y: 0), CGPoint(x: 1920, y: 0)],
        )
        assertEquals(mapping, [CGPoint(x: 0, y: 0): CGPoint(x: 0, y: 0), CGPoint(x: 1920, y: 0): CGPoint(x: 1920, y: 0)])
    }

    /// The second display is dragged from the right of the main one to its left. Both old screens are
    /// nearest to the main one, and the second must still get the screen nobody claimed instead of a
    /// stub workspace.
    func testOldScreenThatLostItsNearestTakesTheUnclaimedOne() {
        let mapping = mapNewScreensToOldScreens(
            oldScreens: [CGPoint(x: 1920, y: 0), CGPoint(x: 0, y: 0)],
            newScreens: [CGPoint(x: 0, y: 0), CGPoint(x: -1920, y: 0)],
        )
        assertEquals(mapping, [CGPoint(x: 0, y: 0): CGPoint(x: 0, y: 0), CGPoint(x: -1920, y: 0): CGPoint(x: 1920, y: 0)])
    }

    func testRemovedScreenIsDroppedWhenNoScreenIsLeft() {
        let mapping = mapNewScreensToOldScreens(
            oldScreens: [CGPoint(x: 0, y: 0), CGPoint(x: 1920, y: 0)],
            newScreens: [CGPoint(x: 0, y: 0)],
        )
        assertEquals(mapping, [CGPoint(x: 0, y: 0): CGPoint(x: 0, y: 0)])
    }

    /// A Monitor captured before a display change can point at a screen that no longer exists.
    /// Asking it for its workspace must not recurse forever.
    func testStaleMonitorFallsBackToTheNearestScreen() {
        let stale = StaleMonitor(rect: Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080))
        assertTrue(stale.activeWorkspace === mainMonitor.activeWorkspace)
    }

    /// When the screen showing the focused workspace goes away, the user stays on that workspace,
    /// now shown on the remaining monitor, instead of keeping focus on a workspace nothing shows.
    func testFocusedWorkspaceThatLostItsScreenIsShownAgain() {
        let focused = Workspace.get(byName: "focused")
        let window = TestWindow.new(id: 1, parent: focused.rootTilingContainer)
        assertTrue(window.focusWindow())
        assertTrue(mainMonitor.setActiveWorkspace(Workspace.get(byName: "other")))
        assertEquals(focused.isVisible, false)

        gcMonitors()

        assertTrue(focused.isVisible)
        assertTrue(mainMonitor.activeWorkspace === focused)
        assertTrue(focus.windowOrNil === window)
    }
}

private struct StaleMonitor: Monitor {
    let monitorAppKitNsScreenScreensId = 2
    let name = "Unplugged Monitor"
    let rect: Rect
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    let isMain = false
}

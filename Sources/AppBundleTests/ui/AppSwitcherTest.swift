@testable import AppBundle
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
}

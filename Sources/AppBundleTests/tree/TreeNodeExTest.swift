@testable import AppBundle
import Common
import XCTest

@MainActor
final class TreeNodeExTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testAllLeafWindowsRecursive() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        let windows = workspace.allLeafWindowsRecursive
        assertEquals(windows.map(\.windowId), [1, 2, 3])
    }

    func testOwnIndex() {
        let workspace = Workspace.get(byName: name)
        var window1: Window!
        var window2: Window!
        var window3: Window!
        workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0)
            window2 = TestWindow.new(id: 2, parent: $0)
            window3 = TestWindow.new(id: 3, parent: $0)
        }
        assertEquals(window1.ownIndex, 0)
        assertEquals(window2.ownIndex, 1)
        assertEquals(window3.ownIndex, 2)
    }

    func testNodeWorkspace() {
        let workspace = Workspace.get(byName: name)
        var window: Window!
        workspace.rootTilingContainer.apply {
            window = TestWindow.new(id: 1, parent: $0)
        }
        assertEquals(window.nodeWorkspace?.name, workspace.name)
        assertEquals(workspace.nodeWorkspace?.name, workspace.name)
    }

    func testMostRecentWindowRecursive() {
        let workspace = Workspace.get(byName: name)
        var window1: Window!
        var window2: Window!
        workspace.rootTilingContainer.apply {
            window1 = TestWindow.new(id: 1, parent: $0)
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                window2 = TestWindow.new(id: 2, parent: $0)
                TestWindow.new(id: 3, parent: $0)
            }
        }
        window2.markAsMostRecentChild()
        window1.markAsMostRecentChild()
        assertEquals(workspace.mostRecentWindowRecursive?.windowId, 1)
    }

    func testAnyLeafWindowRecursive() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 5, parent: $0)
            }
        }
        assertEquals(workspace.anyLeafWindowRecursive?.windowId, 5)
    }

    func testIsEffectivelyEmpty() {
        let workspace = Workspace.get(byName: name)
        assertTrue(workspace.isEffectivelyEmpty)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertTrue(!workspace.isEffectivelyEmpty)
    }
}

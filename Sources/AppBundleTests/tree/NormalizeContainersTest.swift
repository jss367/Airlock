@testable import AppBundle
import Common
import XCTest

@MainActor
final class NormalizeContainersTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testOppositeOrientationNormalization() {
        config.enableNormalizationOppositeOrientationForNestedContainers = true
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
            }
        }
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.v_tiles([.window(1), .window(2)])]),
        )
    }

    func testRemoveDeeplyNestedEmptyContainers() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    _ = TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1)
                }
            }
        }
        assertEquals(workspace.rootTilingContainer.children.count, 1)
        workspace.normalizeContainers()
        assertEquals(workspace.rootTilingContainer.children.count, 0)
    }

    func testFlattenChainedSingleChildContainers() {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                    TestWindow.new(id: 1, parent: $0)
                }
            }
        }
        workspace.normalizeContainers()
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .h_tiles([.window(1)]),
        )
    }

    func testFlattenPreservesMultipleChildren() {
        config.enableNormalizationFlattenContainers = true
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0)
                TestWindow.new(id: 2, parent: $0)
            }
        }
        workspace.normalizeContainers()
        // The root had a single child (v_tiles), so it gets flattened — root becomes v_tiles
        // But the 2 windows inside are preserved
        assertEquals(
            workspace.rootTilingContainer.layoutDescription,
            .v_tiles([.window(1), .window(2)]),
        )
    }

    func testMixedEmptyAndNonEmptyContainers() {
        let workspace = Workspace.get(byName: name)
        workspace.rootTilingContainer.apply {
            _ = TilingContainer.newVTiles(parent: $0, adaptiveWeight: 1)
            TilingContainer.newHTiles(parent: $0, adaptiveWeight: 1).apply {
                TestWindow.new(id: 1, parent: $0)
            }
        }
        workspace.normalizeContainers()
        // Empty container removed, non-empty preserved
        assertEquals(workspace.rootTilingContainer.children.count, 1)
    }

    func testNormalizeDoesNotRemoveRootEvenWhenEmpty() {
        let workspace = Workspace.get(byName: name)
        workspace.normalizeContainers()
        assertNotNil(workspace.rootTilingContainer)
        assertTrue(workspace.rootTilingContainer.children.isEmpty)
    }
}

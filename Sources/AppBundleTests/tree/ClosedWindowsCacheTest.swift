@testable import AppBundle
import XCTest

@MainActor
final class ClosedWindowsCacheTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    // Regression: caching the world when any window closed created the macOS fullscreen and hidden-apps containers
    // in every workspace, and the empty containers became each workspace's most recent child
    func testCachingClosedWindowsKeepsMostRecentWindow() {
        let workspace = Workspace.get(byName: name)
        var b: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            b = TestWindow.new(id: 2, parent: $0)
        }
        b.markAsMostRecentChild()
        let otherWorkspace = Workspace.get(byName: name + "_other")
        TestWindow.new(id: 3, parent: otherWorkspace.rootTilingContainer)

        cacheClosedWindowIfNeeded()

        XCTAssertEqual(workspace.mostRecentWindowRecursive?.windowId, 2)
        XCTAssertEqual(workspace.toLiveFocus().windowOrNil?.windowId, 2)
        XCTAssertNil(workspace.existingMacOsNativeFullscreenWindowsContainer)
        XCTAssertNil(workspace.existingMacOsNativeHiddenAppsWindowsContainer)
    }

    func testCreatingMacosContainersKeepsMostRecentWindow() {
        let workspace = Workspace.get(byName: name)
        var b: TestWindow!
        workspace.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
            b = TestWindow.new(id: 2, parent: $0)
        }
        b.markAsMostRecentChild()

        _ = workspace.macOsNativeFullscreenWindowsContainer
        _ = workspace.macOsNativeHiddenAppsWindowsContainer

        XCTAssertEqual(workspace.mostRecentWindowRecursive?.windowId, 2)
    }

    func testWindowBoundIntoMacosContainerBecomesMostRecent() {
        let workspace = Workspace.get(byName: name)
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let fullscreen = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 3, parent: workspace.rootTilingContainer)

        fullscreen.bind(to: workspace.macOsNativeFullscreenWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)

        XCTAssertEqual(workspace.mostRecentWindowRecursive?.windowId, 2)
    }
}

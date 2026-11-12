@testable import AppBundle
import Common
import XCTest

@MainActor
final class WorkspacesForUiTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testListsPersistentWorkspacesFirstInConfigOrder() {
        config.persistentWorkspaces = ["2", "1"]
        _ = Workspace.get(byName: "extra")
        _ = Workspace.get(byName: "1")
        _ = Workspace.get(byName: "2")
        let shown = focus.workspace.name

        assertEquals(workspacesForUi().map(\.name), ["2", "1", "extra", shown])
    }

    func testListsOnlyShownWorkspacesWithoutWindowManagement() {
        config.enableWindowManagement = false
        config.persistentWorkspaces = ["1", "2"]
        _ = Workspace.get(byName: "1")
        _ = Workspace.get(byName: "2")
        let hidden = Workspace.get(byName: "hidden")
        TestWindow.new(id: 1, parent: hidden.rootTilingContainer)

        assertEquals(workspacesForUi().map(\.name), [focus.workspace.name])
    }
}

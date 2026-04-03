@testable import AppBundle
import Common
import XCTest

@MainActor
final class BackAndForthTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testFocusBackAndForthNoPrevWindow() async throws {
        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
        }
        // prevFocus is nil by default after setup
        let result = try await FocusBackAndForthCommand(args: FocusBackAndForthCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 1)
    }

    func testWorkspaceBackAndForthNoPrev() async throws {
        Workspace.get(byName: name).rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
        }
        assertEquals(Workspace.get(byName: name).focusWorkspace(), true)
        // No previous workspace
        let result = try await WorkspaceBackAndForthCommand(args: WorkspaceBackAndForthCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 1)
    }

    func testWorkspaceBackAndForth() async throws {
        let ws1Name = "\(name)-1"
        let ws2Name = "\(name)-2"
        let ws1 = Workspace.get(byName: ws1Name)
        let ws2 = Workspace.get(byName: ws2Name)
        ws1.rootTilingContainer.apply {
            TestWindow.new(id: 1, parent: $0)
        }
        ws2.rootTilingContainer.apply {
            TestWindow.new(id: 2, parent: $0)
        }

        assertEquals(ws1.focusWorkspace(), true)
        // Manually set prev workspace name to simulate having been on ws1 before
        _prevFocusedWorkspaceName = ws1Name
        assertEquals(ws2.focusWorkspace(), true)

        assertEquals(focus.workspace.name, ws2Name)

        let result = try await WorkspaceBackAndForthCommand(args: WorkspaceBackAndForthCmdArgs(rawArgs: [])).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 0)
        assertEquals(focus.workspace.name, ws1Name)
    }
}

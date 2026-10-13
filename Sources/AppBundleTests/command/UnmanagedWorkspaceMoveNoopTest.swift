@testable import AppBundle
import Common
import XCTest

@MainActor
final class UnmanagedWorkspaceMoveNoopTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.enableWindowManagement = false
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
    }

    func testSameWorkspacePreservesNoopExitSemantics() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertTrue(window.focusWindow())
        let parent = window.parent
        for failIfNoop in [false, true] {
            for followsFocus in [false, true] {
                let flags = (failIfNoop ? " --fail-if-noop" : "") + (followsFocus ? " --focus-follows-window" : "")
                let result = try await parseCommand("move-node-to-workspace\(flags) \(workspace.name)")
                    .cmdOrDie.run(.defaultEnv, .emptyStdin)
                XCTAssertEqual(result.exitCode, failIfNoop ? 1 : 0, flags)
                XCTAssertFalse(result.stderr.joined().contains("requires window management"), flags)
                XCTAssertTrue(window.parent === parent)
                XCTAssertTrue(focus.workspace === workspace)
            }
        }
    }

    func testDifferentWorkspaceRejectsActualMoveForEitherNoopFlag() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        XCTAssertTrue(window.focusWindow())
        let parent = window.parent
        for failIfNoop in [false, true] {
            for followsFocus in [false, true] {
                let flags = (failIfNoop ? " --fail-if-noop" : "") + (followsFocus ? " --focus-follows-window" : "")
                let result = try await parseCommand("move-node-to-workspace\(flags) other-workspace")
                    .cmdOrDie.run(.defaultEnv, .emptyStdin)
                XCTAssertEqual(result.exitCode, 1, flags)
                XCTAssertTrue(result.stderr.joined().contains("requires window management"), flags)
                XCTAssertTrue(window.parent === parent)
                XCTAssertTrue(focus.workspace === workspace)
            }
        }
    }
}

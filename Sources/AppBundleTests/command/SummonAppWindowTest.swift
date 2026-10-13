@testable import AppBundle
import Common
import XCTest

@MainActor
final class SummonAppWindowTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        config.quickSwitcher.enabled = false
        config.focusFlash.enabled = false
    }

    func testUnmanagedSummonRejectsCrossWorkspaceMoveWithoutChangingWindow() {
        config.enableWindowManagement = false
        let destination = focus.workspace
        let source = Workspace.get(byName: "source")
        let rect = Rect(topLeftX: 120, topLeftY: 140, width: 500, height: 300)
        let window = TestWindow.new(id: 1, parent: source.rootTilingContainer, rect: rect)
        let parent = window.parent
        let io = CmdIo(stdin: .emptyStdin)

        XCTAssertFalse(summonAppWindow(window, to: destination, io: io))

        XCTAssertTrue(io.stderr.joined().contains("requires window management"))
        XCTAssertTrue(window.parent === parent)
        XCTAssertTrue(window.nodeWorkspace === source)
        XCTAssertTrue(focus.workspace === destination)
        XCTAssertEqual(window._rect?.topLeftCorner, rect.topLeftCorner)
    }

    func testUnmanagedSummonCanFocusExistingWindowOnCurrentWorkspace() {
        config.enableWindowManagement = false
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let chosen = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        XCTAssertTrue(first.focusWindow())
        let parent = chosen.parent
        let io = CmdIo(stdin: .emptyStdin)

        XCTAssertTrue(summonAppWindow(chosen, to: workspace, io: io))

        XCTAssertTrue(io.stderr.isEmpty)
        XCTAssertTrue(chosen.parent === parent)
        XCTAssertTrue(focus.windowOrNil === chosen)
    }

    func testManagedSummonStillMovesAndFocusesExistingWindow() {
        let destination = focus.workspace
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "source").rootTilingContainer)
        let io = CmdIo(stdin: .emptyStdin)

        XCTAssertTrue(summonAppWindow(window, to: destination, io: io))

        XCTAssertTrue(io.stderr.isEmpty)
        XCTAssertTrue(window.nodeWorkspace === destination)
        XCTAssertTrue(window.isFloating)
        XCTAssertTrue(focus.windowOrNil === window)
    }
}

@testable import AppBundle
import Common
import XCTest

@MainActor
final class MoveNodeToMonitorCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        testParseCommandSucc("move-node-to-monitor next", MoveNodeToMonitorCmdArgs(target: .relative(.next)))
        testParseCommandSucc("move-node-to-monitor --fail-if-noop main", MoveNodeToMonitorCmdArgs(target: .patterns([.main])).copy(\.failIfNoop, true))
        assertEquals(parseCommand("move-node-to-monitor --fail-if-noop next").errorOrNil, "--fail-if-noop is incompatible with (left|down|up|right|next|prev)")
        assertEquals(parseCommand("move-node-to-monitor --fail-if-noop left").errorOrNil, "--fail-if-noop is incompatible with (left|down|up|right|next|prev)")
    }

    func testUnmanagedMaximizeFitsDestinationAndPreservesRestoreFrame() async throws {
        config.enableWindowManagement = false
        config.gaps.outer = .init(left: 10, bottom: 20, top: 30, right: 40)
        let destination = mainMonitor
        let command = MoveNodeToMonitorCommand(args: MoveNodeToMonitorCmdArgs(target: .patterns([.main])))
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        XCTAssertTrue(window.focusWindow())

        for sourceSize in [CGSize(width: 3000, height: 1800), CGSize(width: 1000, height: 600)] {
            let source = MonitorMoveSourceFixture(rect: Rect(topLeftX: -3000, topLeftY: 25, width: sourceSize.width, height: sourceSize.height))
            let restoreFrame = Rect(topLeftX: source.rect.minX + source.rect.width * 0.1,
                                    topLeftY: source.rect.minY + source.rect.height * 0.1, width: 600, height: 400)
            for noOuterGaps in [false, true] {
                window._rect = source.visibleRect
                window.isFullscreen = true
                window.noOuterGapsInFullscreen = noOuterGaps
                window.lastFloatingSize = restoreFrame.size
                window.floatingFullscreenRestore = FloatingFullscreenRestore(frame: restoreFrame, monitorVisibleRect: source.visibleRect)

                let result = try await command.moveUnmanagedWindow(window, nativeRect: source.visibleRect,
                                                                   from: source, to: destination, CmdIo(stdin: .emptyStdin))
                XCTAssertTrue(result)
                try await layoutWorkspaces()
                assertEquals(window._rect, noOuterGaps ? destination.visibleRect : destination.visibleRectPaddedByOuterGaps)
                XCTAssertTrue(window.isFullscreen)
                assertEquals(window.floatingFullscreenRestore?.frame, restoreFrame)
                assertEquals(window.lastFloatingSize, restoreFrame.size)
                XCTAssertTrue(window.nodeWorkspace === destination.activeWorkspace)
                XCTAssertTrue(focus.windowOrNil === window)

                try await parseCommand("fullscreen off").cmdOrDie.run(.defaultEnv, .emptyStdin)
                try await layoutWorkspaces()
                assertEquals(window._rect, Rect(topLeftX: 192, topLeftY: 108, width: 600, height: 400))
            }
        }
    }

    func testUnmanagedMonitorMovePreservesUnmaximizedWindowSize() async throws {
        config.enableWindowManagement = false
        let source = MonitorMoveSourceFixture(rect: Rect(topLeftX: -2000, topLeftY: 0, width: 2000, height: 1000))
        let frame = Rect(topLeftX: -1800, topLeftY: 100, width: 600, height: 400)
        let window = TestWindow.new(id: 1, parent: focus.workspace, rect: frame)
        let command = MoveNodeToMonitorCommand(args: MoveNodeToMonitorCmdArgs(target: .patterns([.main])))

        let result = try await command.moveUnmanagedWindow(window, nativeRect: frame, from: source, to: mainMonitor, CmdIo(stdin: .emptyStdin))
        XCTAssertTrue(result)
        assertEquals(window._rect, Rect(topLeftX: 192, topLeftY: 108, width: 600, height: 400))
        XCTAssertFalse(window.isFullscreen)
    }
}

private struct MonitorMoveSourceFixture: Monitor {
    let rect: Rect
    var visibleRect: Rect { rect }
    var width: CGFloat { rect.width }
    var height: CGFloat { rect.height }
    let monitorAppKitNsScreenScreensId = 2
    let name = "Source monitor"
    let isMain = false
}

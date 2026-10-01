@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class UnmanagedWindowsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testRefreshLeavesWindowFrameAloneAndManagementCanResume() async throws {
        config.enableWindowManagement = false
        let rect = Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400)
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer, rect: rect)
        XCTAssertTrue(window.focusWindow())

        try await layoutWorkspaces()
        assertEquals(window._rect?.topLeftCorner, rect.topLeftCorner)
        assertEquals(window._rect?.width, rect.width)
        assertEquals(window._rect?.height, rect.height)

        config.enableWindowManagement = true
        try await layoutWorkspaces()
        XCTAssertNotEqual(window._rect?.width, rect.width)
        XCTAssertNotEqual(window._rect?.height, rect.height)
    }

    func testNativePositionUpdatesWorkspaceWithoutMovingWindow() async throws {
        config.enableWindowManagement = false
        let visibleWorkspace = mainMonitor.activeWorkspace
        let oldWorkspace = Workspace.get(byName: "old")
        let rect = Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400)
        let window = TestWindow.new(id: 1, parent: oldWorkspace.rootTilingContainer, rect: rect)

        try await syncUnmanagedWindow(window)

        XCTAssertTrue(window.nodeWorkspace === visibleWorkspace)
        XCTAssertFalse(window.isFloating)
        assertEquals(window._rect?.topLeftCorner, rect.topLeftCorner)
        assertEquals(window._rect?.width, rect.width)
        assertEquals(window._rect?.height, rect.height)
    }

    func testFloatingWindowStaysFloating() async throws {
        let visibleWorkspace = mainMonitor.activeWorkspace
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "old"),
                                    rect: Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400))
        try await syncUnmanagedWindow(window)
        XCTAssertTrue(window.nodeWorkspace === visibleWorkspace)
        XCTAssertTrue(window.isFloating)
    }

    func testUnmanagedFocusIsNotBlockedAcrossWorkspaces() {
        config.enableWindowManagement = false
        config.preventFocusStealing = .always
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: "other").rootTilingContainer)
        XCTAssertTrue(shouldAllowFocusChange(to: window))
        XCTAssertTrue(updateFocusCache(window))
        assertEquals(focus.windowOrNil?.windowId, window.windowId)
    }

    func testRelativePositionOnAnotherMonitor() {
        let source = Rect(topLeftX: 0, topLeftY: 25, width: 2000, height: 1000)
        let destination = Rect(topLeftX: -1000, topLeftY: -475, width: 1000, height: 500)
        let window = Rect(topLeftX: 200, topLeftY: 125, width: 300, height: 200)
        assertEquals(windowPositionOnMonitor(window, from: source, to: destination), CGPoint(x: -900, y: -425))
    }

    func testSmallerMonitorClampsWindowPosition() {
        let source = Rect(topLeftX: 0, topLeftY: 0, width: 2000, height: 1000)
        let destination = Rect(topLeftX: 2000, topLeftY: 0, width: 1000, height: 500)
        let window = Rect(topLeftX: 1600, topLeftY: 800, width: 600, height: 400)
        assertEquals(windowPositionOnMonitor(window, from: source, to: destination), CGPoint(x: 2400, y: 100))
        let oversized = Rect(topLeftX: 100, topLeftY: 100, width: 1500, height: 800)
        assertEquals(windowPositionOnMonitor(oversized, from: source, to: destination), CGPoint(x: 2000, y: 0))
    }

    func testSameMonitorCommandDoesNotResizeUnmanagedWindow() async throws {
        config.enableWindowManagement = false
        let rect = Rect(topLeftX: 120, topLeftY: 140, width: 500, height: 300)
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer, rect: rect)
        XCTAssertTrue(window.focusWindow())
        let result = try await MoveNodeToMonitorCommand(args: MoveNodeToMonitorCmdArgs(target: .patterns([.main])))
            .run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 0)
        assertEquals(window._rect?.topLeftCorner, rect.topLeftCorner)
        assertEquals(window._rect?.width, rect.width)
        assertEquals(window._rect?.height, rect.height)
    }
}

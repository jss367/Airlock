@testable import AppBundle
import Common
import XCTest

@MainActor
final class FullscreenCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testToggleFullscreen() async throws {
        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
        }
        let window = focus.windowOrNil!
        assertEquals(window.isFullscreen, false)

        try await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isFullscreen, true)

        try await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isFullscreen, false)
    }

    func testFloatingMaximizeSurvivesRefreshAndRestoresExactFrame() async throws {
        let frame = Rect(topLeftX: 123, topLeftY: 145, width: 650, height: 430)
        let window = TestWindow.new(id: 1, parent: focus.workspace, rect: frame)
        XCTAssertTrue(window.focusWindow())

        for _ in 0 ..< 2 {
            try await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
            try await layoutWorkspaces()
            try await layoutWorkspaces()
            XCTAssertTrue(window.isFullscreen)
            assertEquals(window._rect, mainMonitor.visibleRect)

            let noop = try await parseCommand("fullscreen on").cmdOrDie.run(.defaultEnv, .emptyStdin)
            assertEquals(noop.exitCode, 0)
            try await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
            try await layoutWorkspaces()
            XCTAssertFalse(window.isFullscreen)
            assertEquals(window._rect, frame)
            assertEquals(window.lastFloatingSize, frame.size)
            XCTAssertNil(window.floatingFullscreenRestore)
        }
    }

    func testRestoreFramesBelongToEachWindow() async throws {
        let firstFrame = Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400)
        let secondFrame = Rect(topLeftX: 200, topLeftY: 240, width: 700, height: 500)
        let first = TestWindow.new(id: 1, parent: focus.workspace, rect: firstFrame)
        let second = TestWindow.new(id: 2, parent: focus.workspace, rect: secondFrame)
        for id in [1, 2] {
            try await parseCommand("fullscreen --window-id \(id) on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        }
        try await layoutWorkspaces()
        for id in [1, 2] {
            try await parseCommand("fullscreen --window-id \(id) off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        }
        try await layoutWorkspaces()
        assertEquals(first._rect, firstFrame)
        assertEquals(second._rect, secondFrame)
    }

    func testMaximizeAndRestoreWithoutAutomaticWindowManagement() async throws {
        config.enableWindowManagement = false
        let frame = Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400)
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer, rect: frame)
        XCTAssertTrue(window.focusWindow())
        try await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await layoutWorkspaces()
        assertEquals(window._rect, mainMonitor.visibleRect)
        try await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window._rect, frame)
    }

    func testResizeAndNudgeExitFloatingMaximize() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace,
                                    rect: Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400))
        XCTAssertTrue(window.focusWindow())
        for command in ["resize width -50", "move left"] {
            try await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
            try await layoutWorkspaces()
            try await parseCommand(command).cmdOrDie.run(.defaultEnv, .emptyStdin)
            let adjustedFrame = window._rect
            try await layoutWorkspaces()
            XCTAssertFalse(window.isFullscreen)
            XCTAssertNil(window.floatingFullscreenRestore)
            assertEquals(window._rect, adjustedFrame)
        }
    }

    func testRestoreOnAnotherMonitorTranslatesSavedPosition() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace, rect: mainMonitor.visibleRect)
        XCTAssertTrue(window.focusWindow())
        window.isFullscreen = true
        window.floatingFullscreenRestore = FloatingFullscreenRestore(
            frame: Rect(topLeftX: -1800, topLeftY: 100, width: 600, height: 400),
            monitorVisibleRect: Rect(topLeftX: -2000, topLeftY: 0, width: 2000, height: 1000),
        )
        try await parseCommand("fullscreen off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window._rect, Rect(topLeftX: 192, topLeftY: 108, width: 600, height: 400))
    }

    func testFullscreenOn() async throws {
        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
        }
        let window = focus.windowOrNil!

        try await parseCommand("fullscreen on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isFullscreen, true)
    }

    func testFullscreenOff() async throws {
        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
        }
        let window = focus.windowOrNil!
        window.isFullscreen = true

        try await parseCommand("fullscreen off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isFullscreen, false)
    }

    func testFullscreenOnAlreadyFullscreen_noFailIfNoop() async throws {
        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
        }
        let window = focus.windowOrNil!
        window.isFullscreen = true

        // Without --fail-if-noop, returns success even if already fullscreen
        let result = try await parseCommand("fullscreen on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 0)
    }

    func testFullscreenOnAlreadyFullscreen_failIfNoop() async throws {
        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
        }
        let window = focus.windowOrNil!
        window.isFullscreen = true

        let result = try await parseCommand("fullscreen --fail-if-noop on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 1)
    }

    func testFullscreenOffAlreadyOff_failIfNoop() async throws {
        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
        }
        let window = focus.windowOrNil!
        assertEquals(window.isFullscreen, false)

        let result = try await parseCommand("fullscreen --fail-if-noop off").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 1)
    }

    func testFullscreenNoOuterGaps() async throws {
        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
        }
        let window = focus.windowOrNil!

        try await parseCommand("fullscreen --no-outer-gaps on").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(window.isFullscreen, true)
        assertEquals(window.noOuterGapsInFullscreen, true)
    }

    func testNoWindowFocused() async throws {
        _ = Workspace.get(byName: name)
        let result = try await parseCommand("fullscreen").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 1)
    }

    func testParseFullscreenNoOuterGapsOff() {
        assertEquals(
            parseCommand("fullscreen --no-outer-gaps off").errorOrNil,
            "--no-outer-gaps is incompatible with 'off' argument",
        )
    }

    func testParseFullscreenFailIfNoopRequiresOnOff() {
        assertEquals(
            parseCommand("fullscreen --fail-if-noop").errorOrNil,
            "--fail-if-noop requires 'on' or 'off' argument",
        )
    }
}

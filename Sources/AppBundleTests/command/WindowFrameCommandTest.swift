@testable import AppBundle
import Common
import XCTest

@MainActor
final class WindowFrameCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testPresetsSurviveLayoutAndMakeWindowFloating() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer,
                                    rect: Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400))
        XCTAssertTrue(window.focusWindow())
        let expected: [(String, Rect)] = [
            ("center", Rect(topLeftX: 660, topLeftY: 340, width: 600, height: 400)),
            ("left-half", Rect(topLeftX: 0, topLeftY: 0, width: 960, height: 1080)),
            ("right-half", Rect(topLeftX: 960, topLeftY: 0, width: 960, height: 1080)),
            ("comfortable", Rect(topLeftX: 240, topLeftY: 135, width: 1440, height: 810)),
        ]
        for (preset, frame) in expected {
            let result = try await parseCommand("window-frame \(preset)").cmdOrDie.run(.defaultEnv, .emptyStdin)
            assertEquals(result.exitCode, 0)
            try await layoutWorkspaces()
            assertEquals(window._rect, frame)
            assertEquals(window.lastFloatingSize, frame.size)
            XCTAssertTrue(window.isFloating)
        }
    }

    func testPresetsUseMonitorOriginAndUsableArea() {
        let visible = Rect(topLeftX: -1600, topLeftY: -300, width: 1600, height: 900)
        let current = Rect(topLeftX: -1500, topLeftY: -200, width: 600, height: 400)
        assertEquals(windowFrame(.leftHalf, current: current, visible: visible),
                     Rect(topLeftX: -1600, topLeftY: -300, width: 800, height: 900))
        assertEquals(windowFrame(.rightHalf, current: current, visible: visible),
                     Rect(topLeftX: -800, topLeftY: -300, width: 800, height: 900))
        assertEquals(windowFrame(.center, current: current, visible: visible),
                     Rect(topLeftX: -1100, topLeftY: -50, width: 600, height: 400))
        assertEquals(windowFrame(.comfortable, current: current, visible: visible),
                     Rect(topLeftX: -1400, topLeftY: -187.5, width: 1200, height: 675))
    }

    func testWindowIdTargetsAnotherWindowAndClearsMaximize() async throws {
        let focused = TestWindow.new(id: 1, parent: focus.workspace,
                                     rect: Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400))
        let other = TestWindow.new(id: 2, parent: focus.workspace, rect: focused._rect)
        XCTAssertTrue(focused.focusWindow())
        try await parseCommand("fullscreen --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let result = try await parseCommand("window-frame --window-id 2 right-half").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 0)
        try await layoutWorkspaces()
        assertEquals(focused._rect, Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400))
        assertEquals(other._rect, Rect(topLeftX: 960, topLeftY: 0, width: 960, height: 1080))
        XCTAssertFalse(other.isFullscreen)
        XCTAssertNil(other.floatingFullscreenRestore)
        XCTAssertTrue(focus.windowOrNil === focused)
    }

    func testWorksWithoutAutomaticWindowManagement() async throws {
        config.enableWindowManagement = false
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer,
                                    rect: Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400))
        XCTAssertTrue(window.focusWindow())
        let result = try await parseCommand("window-frame comfortable").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 0)
        try await layoutWorkspaces()
        assertEquals(window._rect, Rect(topLeftX: 240, topLeftY: 135, width: 1440, height: 810))
    }

    func testMissingFrameOrClosedWindowDoesNotChangeTree() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        XCTAssertTrue(window.focusWindow())
        let missingFrame = try await parseCommand("window-frame center").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(missingFrame.exitCode, 1)
        XCTAssertFalse(window.isFloating)

        window._rect = Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400)
        window.duringGetAxRect = { [unowned window] in window.closeAxWindow() }
        let closed = try await parseCommand("window-frame center").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(closed.exitCode, 1)
        XCTAssertFalse(window.isBound)
    }

    func testInvalidPresetAndMissingWindow() async throws {
        XCTAssertNotNil(parseCommand("window-frame").errorOrNil)
        XCTAssertNotNil(parseCommand("window-frame invalid").errorOrNil)
        let result = try await parseCommand("window-frame center").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 1)
    }
}

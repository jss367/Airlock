@testable import AppBundle
import Common
import XCTest

@MainActor
final class WindowKeyBindingsTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func runBinding(_ suffix: String) async throws {
        let binding = try XCTUnwrap(defaultConfig.modes[mainModeId]?.bindings.values.first {
            $0.descriptionWithKeyNotation == "ctrl-option-cmd-\(suffix)"
        })
        let result = try await binding.commands.runCmdSeq(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 0)
        try await layoutWorkspaces()
    }

    func testNudgeKeysFloatAtCurrentFrameAndMoveInExpectedDirections() async throws {
        let frame = Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400)
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer, rect: frame)
        // An older floating size must not replace the current frame on the first nudge.
        window.lastFloatingSize = CGSize(width: 300, height: 200)
        XCTAssertTrue(window.focusWindow())
        let expected: [(String, CGFloat, CGFloat)] = [("i", 100, 70), ("j", 50, 70), ("k", 50, 120), ("l", 100, 120)]
        for (key, x, y) in expected {
            try await runBinding(key)
            assertEquals(window._rect, Rect(topLeftX: x, topLeftY: y, width: 600, height: 400))
            XCTAssertTrue(window.isFloating)
        }
    }

    func testResizeKeysFloatAtCurrentFrameAndKeepUpperLeftFixed() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer,
                                    rect: Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400))
        window.lastFloatingSize = CGSize(width: 300, height: 200)
        XCTAssertTrue(window.focusWindow())
        let expected: [(String, CGFloat, CGFloat)] = [("shift-i", 600, 350), ("shift-j", 550, 350), ("shift-k", 550, 400), ("shift-l", 600, 400)]
        for (key, width, height) in expected {
            try await runBinding(key)
            assertEquals(window._rect, Rect(topLeftX: 100, topLeftY: 120, width: width, height: height))
            assertEquals(window.lastFloatingSize, CGSize(width: width, height: height))
            XCTAssertTrue(window.isFloating)
        }
    }

    func testSnapCenterPresetAndMaximizeBindings() async throws {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer,
                                    rect: Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400))
        XCTAssertTrue(window.focusWindow())
        try await runBinding("h")
        assertEquals(window._rect, Rect(topLeftX: 0, topLeftY: 0, width: 960, height: 1080))
        try await runBinding("semicolon")
        assertEquals(window._rect, Rect(topLeftX: 960, topLeftY: 0, width: 960, height: 1080))
        try await runBinding("c")
        assertEquals(window._rect, Rect(topLeftX: 480, topLeftY: 0, width: 960, height: 1080))
        try await runBinding("space")
        let comfortable = window._rect
        assertEquals(comfortable, Rect(topLeftX: 240, topLeftY: 135, width: 1440, height: 810))
        try await runBinding("m")
        assertEquals(window._rect, mainMonitor.visibleRect)
        try await runBinding("m")
        assertEquals(window._rect, comfortable)
    }

    func testMonitorBindingsUseSpatialDirectionsAndFollowWindow() throws {
        for (key, direction) in [("h", CardinalDirection.left), ("semicolon", .right)] {
            let binding = try XCTUnwrap(defaultConfig.modes[mainModeId]?.bindings.values.first {
                $0.descriptionWithKeyNotation == "ctrl-option-cmd-shift-\(key)"
            })
            let command = try XCTUnwrap(binding.commands.first as? MoveNodeToMonitorCommand)
            assertEquals(command.args.target.val, .direction(direction))
            XCTAssertTrue(command.args.focusFollowsWindow)
            XCTAssertFalse(command.args.wrapAround)
        }
    }

    func testNativeWindowsNudgeAndResizeWhenManagementIsOff() async throws {
        config.enableWindowManagement = false
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer,
                                    rect: Rect(topLeftX: 100, topLeftY: 120, width: 600, height: 400))
        XCTAssertTrue(window.focusWindow())
        try await parseCommand("move right").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await parseCommand("resize height +50").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await layoutWorkspaces()
        assertEquals(window._rect, Rect(topLeftX: 150, topLeftY: 120, width: 600, height: 450))
        XCTAssertFalse(window.isFloating)
    }
}

@testable import AppBundle
import Common
import XCTest

@MainActor
final class FocusAttentionCommandTest: XCTestCase {
    private var current: Window!
    private var other: Window!
    private var third: Window!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        current = TestWindow.new(id: 1, parent: Workspace.get(byName: "focused").rootTilingContainer)
        other = TestWindow.new(id: 2, parent: Workspace.get(byName: "other").rootTilingContainer)
        // Not the workspace's most recent window, so focusing the workspace alone wouldn't pick it
        TestWindow.new(id: 3, parent: Workspace.get(byName: "other").rootTilingContainer)
        third = TestWindow.new(id: 4, parent: Workspace.get(byName: "third").rootTilingContainer)
        check(current.focusWindow())
        _ = updateFocusCache(current)
    }

    private func runCommand() async throws -> CmdResult {
        try await parseCommand("focus-attention").cmdOrDie.run(.defaultEnv, .emptyStdin)
    }

    func testParse() {
        assertTrue(parseCommand("focus-attention").cmdOrNil is FocusAttentionCommand)
        assertNotNil(parseCommand("focus-attention extra").errorOrNil)
    }

    func testNothingPendingIsANoop() async throws {
        let result = try await runCommand()
        assertEquals(result.exitCode, 1)
        assertEquals(result.stderr, ["No window is waiting for focus"])
        assertTrue(focus.windowOrNil === current)
    }

    func testFocusesTheBlockedWindowOnItsWorkspace() async throws {
        assertEquals(updateFocusCache(other), false)
        let result = try await runCommand()
        assertEquals(result.exitCode, 0)
        assertTrue(focus.windowOrNil === other)
        assertEquals(focus.workspace.name, "other")
        assertEquals(focusAttention.pending, [])
    }

    /// The most recent request first, then the one before it. Then there is nothing left.
    func testRepeatingWalksBackThroughTheRequests() async throws {
        assertEquals(updateFocusCache(third), false)
        assertEquals(updateFocusCache(other), false)

        assertEquals(try await runCommand().exitCode, 0)
        assertTrue(focus.windowOrNil === other)
        assertEquals(try await runCommand().exitCode, 0)
        assertTrue(focus.windowOrNil === third)
        assertEquals(try await runCommand().exitCode, 1)
        assertTrue(focus.windowOrNil === third)
    }

    func testAlwaysModeFocusesABlockedWindowOnTheFocusedWorkspace() async throws {
        config.preventFocusStealing = .always
        let sameWorkspace = TestWindow.new(id: 5, parent: Workspace.get(byName: "focused").rootTilingContainer)
        assertEquals(updateFocusCache(sameWorkspace), false)
        assertEquals(try await runCommand().exitCode, 0)
        assertTrue(focus.windowOrNil === sameWorkspace)
        assertEquals(focusAttention.pending, [])
    }

    func testDefaultConfigBindsIt() {
        let binding = defaultConfig.modes[mainModeId]?.bindings[HotkeyBinding(.option, .grave, []).descriptionWithKeyCode]
        assertEquals(binding?.commands.count, 1)
        assertTrue(binding?.commands.first is FocusAttentionCommand)
    }
}

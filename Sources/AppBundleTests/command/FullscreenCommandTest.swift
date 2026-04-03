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

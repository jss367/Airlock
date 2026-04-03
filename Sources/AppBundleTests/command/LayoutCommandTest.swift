@testable import AppBundle
import Common
import XCTest

@MainActor
final class LayoutCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseLayout() {
        testParseCommandSucc("layout tiles", LayoutCmdArgs(rawArgs: ["layout", "tiles"], toggleBetween: [.tiles]))
        testParseCommandSucc("layout accordion", LayoutCmdArgs(rawArgs: ["layout", "accordion"], toggleBetween: [.accordion]))
        testParseCommandSucc("layout floating", LayoutCmdArgs(rawArgs: ["layout", "floating"], toggleBetween: [.floating]))
    }

    func testParseLayoutToggleBetween() {
        testParseCommandSucc(
            "layout tiles accordion",
            LayoutCmdArgs(rawArgs: ["layout", "tiles", "accordion"], toggleBetween: [.tiles, .accordion]),
        )
    }

    func testParseLayoutInvalidValue() {
        testParseCommandFail("layout foobar", msg: "ERROR: Can't parse 'foobar'\n       Possible values: (accordion|tiles|horizontal|vertical|h_accordion|v_accordion|h_tiles|v_tiles|tiling|floating)")
    }

    func testParseLayoutListAlias() {
        testParseCommandSucc("layout list", LayoutCmdArgs(rawArgs: ["layout", "list"], toggleBetween: [.tiles]))
    }

    func testSwitchToAccordion() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }
        assertEquals(root.layout, .tiles)

        try await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.accordion])).run(.defaultEnv, .emptyStdin)
        assertEquals(root.layout, .accordion)
    }

    func testSwitchToVTiles() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }
        assertEquals(root.orientation, .h)

        try await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.v_tiles])).run(.defaultEnv, .emptyStdin)
        assertEquals(root.orientation, .v)
        assertEquals(root.layout, .tiles)
    }

    func testSwitchToHAccordion() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }

        try await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.h_accordion])).run(.defaultEnv, .emptyStdin)
        assertEquals(root.layout, .accordion)
        assertEquals(root.orientation, .h)
    }

    func testToggleBetweenTilesAndAccordion() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }
        assertEquals(root.layout, .tiles)

        let args = LayoutCmdArgs(rawArgs: [], toggleBetween: [.tiles, .accordion])

        try await LayoutCommand(args: args).run(.defaultEnv, .emptyStdin)
        assertEquals(root.layout, .accordion)

        try await LayoutCommand(args: args).run(.defaultEnv, .emptyStdin)
        assertEquals(root.layout, .tiles)
    }

    func testChangeOrientationOnly() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }
        assertEquals(root.orientation, .h)

        try await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.vertical])).run(.defaultEnv, .emptyStdin)
        assertEquals(root.orientation, .v)
        assertEquals(root.layout, .tiles) // layout unchanged
    }

    func testToggleHorizontalVertical() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }
        let args = LayoutCmdArgs(rawArgs: [], toggleBetween: [.horizontal, .vertical])

        try await LayoutCommand(args: args).run(.defaultEnv, .emptyStdin)
        assertEquals(root.orientation, .v)

        try await LayoutCommand(args: args).run(.defaultEnv, .emptyStdin)
        assertEquals(root.orientation, .h)
    }

    func testLayoutNoWindowFocused() async throws {
        _ = Workspace.get(byName: name)
        let result = try await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.accordion])).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 1)
    }

    func testAlreadyMatchesDescription() async throws {
        Workspace.get(byName: name).rootTilingContainer.apply {
            assertEquals(TestWindow.new(id: 1, parent: $0).focusWindow(), true)
            TestWindow.new(id: 2, parent: $0)
        }
        // Root is already h_tiles
        let result = try await LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.h_tiles])).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 1)
    }
}

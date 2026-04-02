@testable import AppBundle
import Common
import XCTest

@MainActor
final class ResizeCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseCommand() {
        testParseCommandSucc("resize smart +10", ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .add(10)))
        testParseCommandSucc("resize smart -10", ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .subtract(10)))
        testParseCommandSucc("resize smart 10", ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .set(10)))

        testParseCommandSucc("resize smart-opposite +10", ResizeCmdArgs(rawArgs: [], dimension: .smartOpposite, units: .add(10)))
        testParseCommandSucc("resize smart-opposite -10", ResizeCmdArgs(rawArgs: [], dimension: .smartOpposite, units: .subtract(10)))
        testParseCommandSucc("resize smart-opposite 10", ResizeCmdArgs(rawArgs: [], dimension: .smartOpposite, units: .set(10)))

        testParseCommandSucc("resize height 10", ResizeCmdArgs(rawArgs: [], dimension: .height, units: .set(10)))
        testParseCommandSucc("resize width 10", ResizeCmdArgs(rawArgs: [], dimension: .width, units: .set(10)))

        testParseCommandFail("resize s 10", msg: """
            ERROR: Can't parse 's'.
                   Possible values: (width|height|smart|smart-opposite)
            """)
        testParseCommandFail("resize smart foo", msg: "ERROR: <number> argument must be a number")
    }

    func testResizeFloatingWindow_addWidth() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace, rect: Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 300))
        assertEquals(window.focusWindow(), true)
        assertEquals(window.isFloating, true)

        let result = try await ResizeCommand(args: ResizeCmdArgs(rawArgs: [], dimension: .width, units: .add(50))).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 0)

        let size = try await window.getAxSize()
        assertEquals(size?.width, 250)
        assertEquals(size?.height, 300)
    }

    func testResizeFloatingWindow_subtractHeight() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace, rect: Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 300))
        assertEquals(window.focusWindow(), true)

        let result = try await ResizeCommand(args: ResizeCmdArgs(rawArgs: [], dimension: .height, units: .subtract(50))).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 0)

        let size = try await window.getAxSize()
        assertEquals(size?.width, 200)
        assertEquals(size?.height, 250)
    }

    func testResizeFloatingWindow_setWidth() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace, rect: Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 300))
        assertEquals(window.focusWindow(), true)

        let result = try await ResizeCommand(args: ResizeCmdArgs(rawArgs: [], dimension: .width, units: .set(400))).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 0)

        let size = try await window.getAxSize()
        assertEquals(size?.width, 400)
        assertEquals(size?.height, 300)
    }

    func testResizeFloatingWindow_smart() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace, rect: Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 300))
        assertEquals(window.focusWindow(), true)

        let result = try await ResizeCommand(args: ResizeCmdArgs(rawArgs: [], dimension: .smart, units: .add(100))).run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 0)

        let size = try await window.getAxSize()
        assertEquals(size?.width, 300)  // smart → width for floating
        assertEquals(size?.height, 300)
    }

    func testResizeFloatingWindow_updatesLastFloatingSize() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace, rect: Rect(topLeftX: 100, topLeftY: 100, width: 200, height: 300))
        assertEquals(window.focusWindow(), true)

        try await ResizeCommand(args: ResizeCmdArgs(rawArgs: [], dimension: .width, units: .set(500))).run(.defaultEnv, .emptyStdin)

        assertEquals(window.lastFloatingSize?.width, 500)
        assertEquals(window.lastFloatingSize?.height, 300)
    }
}

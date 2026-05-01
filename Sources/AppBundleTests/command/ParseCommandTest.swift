@testable import AppBundle
import Common
import XCTest

@MainActor
final class ParseCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParseExecAndForget() {
        let parsed = parseCommand("exec-and-forget echo hello")
        switch parsed {
            case .cmd(let command):
                assertTrue(command is ExecAndForgetCommand)
            case .failure(let msg): XCTFail(msg)
            case .help: XCTFail("Unexpected help")
        }
    }

    func testParseUnknownCommand() {
        let parsed = parseCommand("unknown-command-xyz")
        switch parsed {
            case .cmd: XCTFail("Unknown command shouldn't parse")
            case .failure: break // expected
            case .help: break
        }
    }

    func testParseLayoutCommand() {
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

    func testParseLayoutInvalid() {
        testParseCommandFail("layout invalid", msg: "ERROR: Can't parse 'invalid'\n       Possible values: (accordion|tiles|horizontal|vertical|h_accordion|v_accordion|h_tiles|v_tiles|tiling|floating)")
    }

    func testParseFullscreen() {
        let parsed = parseCommand("fullscreen")
        switch parsed {
            case .cmd: break
            case .failure(let msg): XCTFail(msg)
            case .help: XCTFail("Unexpected help")
        }
    }

    func testParseFullscreenOnOff() {
        let parsedOn = parseCommand("fullscreen on")
        switch parsedOn {
            case .cmd: break
            case .failure(let msg): XCTFail(msg)
            case .help: XCTFail("Unexpected help")
        }
        let parsedOff = parseCommand("fullscreen off")
        switch parsedOff {
            case .cmd: break
            case .failure(let msg): XCTFail(msg)
            case .help: XCTFail("Unexpected help")
        }
    }

    func testParseFullscreenInvalidCombinations() {
        assertEquals(
            parseCommand("fullscreen --no-outer-gaps off").errorOrNil,
            "--no-outer-gaps is incompatible with 'off' argument",
        )
        assertEquals(
            parseCommand("fullscreen --fail-if-noop").errorOrNil,
            "--fail-if-noop requires 'on' or 'off' argument",
        )
    }

    func testParseFocusBackAndForth() {
        let parsed = parseCommand("focus-back-and-forth")
        switch parsed {
            case .cmd: break
            case .failure(let msg): XCTFail(msg)
            case .help: XCTFail("Unexpected help")
        }
    }

    func testParseWorkspaceBackAndForth() {
        let parsed = parseCommand("workspace-back-and-forth")
        switch parsed {
            case .cmd: break
            case .failure(let msg): XCTFail(msg)
            case .help: XCTFail("Unexpected help")
        }
    }

    func testParseFlattenWorkspaceTree() {
        let parsed = parseCommand("flatten-workspace-tree")
        switch parsed {
            case .cmd: break
            case .failure(let msg): XCTFail(msg)
            case .help: XCTFail("Unexpected help")
        }
    }

    func testParseLayoutListAlias() {
        testParseCommandSucc("layout list", LayoutCmdArgs(rawArgs: ["layout", "list"], toggleBetween: [.tiles]))
    }

    func testParseCloseAllWindowsButCurrent() {
        let parsed = parseCommand("close-all-windows-but-current")
        switch parsed {
            case .cmd: break
            case .failure(let msg): XCTFail(msg)
            case .help: XCTFail("Unexpected help")
        }
    }

    func testParseFlashFocus() {
        let parsed = parseCommand("flash-focus")
        switch parsed {
            case .cmd(let command):
                assertTrue(command is FlashFocusCommand)
            case .failure(let msg): XCTFail(msg)
            case .help: XCTFail("Unexpected help")
        }
    }

    func testParseFlashFocusRejectsArgs() {
        let parsed = parseCommand("flash-focus extra")
        switch parsed {
            case .cmd: XCTFail("flash-focus should not accept positional args")
            case .failure: break // expected
            case .help: XCTFail("Unexpected help")
        }
    }
}

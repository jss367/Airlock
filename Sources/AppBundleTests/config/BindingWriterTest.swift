@testable import AppBundle
import AppKit
import Common
import HotKey
import XCTest

@MainActor
final class BindingWriterTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func main(_ binding: String) -> BindingAddress { BindingAddress(mode: mainModeId, binding: binding) }

    // MARK: - setBindingInLines

    func testSetReplacesTheBindingWhereItStands() throws {
        let lines = [
            "[mode.main.binding]",
            "    # Focus",
            "\toption-h = 'focus left' # go left",
            "    option-l = 'focus right'",
            "",
            "[mode.resize.binding]",
            "    option-h = 'resize width -50'",
        ]

        let result = try setBindingInLines(lines, main("option-h"), value: "'focus up'")

        assertEquals(result, [
            "[mode.main.binding]",
            "    # Focus",
            "\toption-h = 'focus up' # go left",
            "    option-l = 'focus right'",
            "",
            "[mode.resize.binding]",
            "    option-h = 'resize width -50'",
        ])
    }

    func testSetMatchesTheKeyWhateverTheModifierOrderAndDropsDuplicates() throws {
        let lines = [
            "[mode.main.binding]",
            "    shift-cmd-k = '''exec-and-forget echo a",
            "    echo b'''",
            "    option-l = 'focus right'",
        ]

        let result = try setBindingInLines(lines, main("cmd-shift-k"), value: "'close'")

        assertEquals(result, [
            "[mode.main.binding]",
            "    cmd-shift-k = 'close'",
            "    option-l = 'focus right'",
        ])
    }

    func testSetAddsANewBindingAfterTheLastOneOfItsMode() throws {
        let lines = [
            "[mode.main.binding]",
            "  option-h = 'focus left'",
            "",
            "# About the resize mode",
            "[mode.resize.binding]",
            "    minus = 'resize smart -50'",
        ]

        let result = try setBindingInLines(lines, main("option-l"), value: "['focus right', 'mode resize']")

        assertEquals(result, [
            "[mode.main.binding]",
            "  option-h = 'focus left'",
            "  option-l = ['focus right', 'mode resize']",
            "",
            "# About the resize mode",
            "[mode.resize.binding]",
            "    minus = 'resize smart -50'",
        ])
    }

    func testSetCreatesTheTableOfANewMode() throws {
        let lines = ["start-at-login = true", "", "[mode.main.binding]", "    option-g = 'mode go'", "", ""]

        let result = try setBindingInLines(lines, BindingAddress(mode: "go", binding: "a"), value: "'workspace A'")

        assertEquals(result, [
            "start-at-login = true",
            "",
            "[mode.main.binding]",
            "    option-g = 'mode go'",
            "",
            "[mode.go.binding]",
            "    a = 'workspace A'",
            "",
        ])
        assertEquals(parseConfig(result.joined(separator: "\n")).errors, [])
    }

    func testSetIntoAnEmptyTable() throws {
        let result = try setBindingInLines(["[mode.main.binding]", "", "[gaps]"], main("option-h"), value: "'focus left'")

        assertEquals(result, ["[mode.main.binding]", "    option-h = 'focus left'", "", "[gaps]"])
    }

    func testSetKeepsAMultiLineValueOnItsOwnLines() throws {
        let script = "exec-and-forget osascript -e '\ntell application \"Finder\" to activate'\n"
        let lines = ["[mode.main.binding]", "    option-f = 'close' # old", "    option-l = 'focus right'"]

        let result = try setBindingInLines(lines, main("option-f"), value: tomlCommandsValue([script]))

        // The comment can't follow a value that ends on another line
        assertEquals(result, [
            "[mode.main.binding]",
            "    option-f = '''exec-and-forget osascript -e '",
            "tell application \"Finder\" to activate'",
            "'''",
            "    option-l = 'focus right'",
        ])
        assertEquals(bindingCommandTexts(inToml: result.joined(separator: "\n"), main("option-f")), [script])
        // And the result is still editable line by line
        assertEquals(try setBindingInLines(result, main("option-f"), value: "'close'"), ["[mode.main.binding]", "    option-f = 'close'", "    option-l = 'focus right'"])
    }

    func testSetRefusesShapesItCantEditAndBadInput() {
        // An inline table has no lines of its own to edit
        XCTAssertThrowsError(try setBindingInLines(["mode.main.binding = { option-h = 'focus left' }"], main("option-h"), value: "'close'"))
        XCTAssertThrowsError(try setBindingInLines(["[mode.main.binding]"], main("option-nokey"), value: "'close'")) { error in
            assertEquals(error.localizedDescription, "'option-nokey' isn't a key Airlock can bind. Write it like 'ctrl-option-k'")
        }
        XCTAssertThrowsError(try setBindingInLines([], BindingAddress(mode: "my mode", binding: "a"), value: "'close'")) { error in
            assertEquals(error.localizedDescription, "'my mode' can't be used as a mode name here. Use letters, digits, '-' and '_'")
        }
        XCTAssertThrowsError(try setBindingInLines(["[mode.main.binding"], main("option-h"), value: "'close'"))
    }

    func testSetUsesTheKeyMappingToFindTheLine() throws {
        // Under dvorak the key written 'o' is the physical S key, and so is the one written 's' in qwerty
        let dvorak = KeyMapping(preset: .dvorak, rawKeyNotationToKeyCode: [:]).resolve()
        let lines = ["[key-mapping]", "    preset = 'dvorak'", "[mode.main.binding]", "    option-o = 'focus left'"]

        let result = try setBindingInLines(lines, main("option-o"), value: "'focus right'", keyMapping: dvorak)

        assertEquals(result.last, "    option-o = 'focus right'")
        assertEquals(result.count, lines.count)
    }

    // MARK: - removeBindingFromLines

    func testRemoveDeletesABindingTheDefaultsDontHave() throws {
        let lines = ["[mode.main.binding]", "    ctrl-option-k = 'close' # bye", "    ctrl-option-j = 'fullscreen'"]

        assertEquals(try removeBindingFromLines(lines, main("option-ctrl-k")), ["[mode.main.binding]", "    ctrl-option-j = 'fullscreen'"])
        // Nothing to remove
        assertEquals(try removeBindingFromLines(lines, main("ctrl-option-z")), lines)
        assertEquals(try removeBindingFromLines(lines, BindingAddress(mode: "nope", binding: "ctrl-option-k")), lines)
    }

    func testRemoveDisablesABindingTheDefaultsStillProvide() throws {
        // option-h is 'focus left' in the default config
        let overridden = ["[mode.main.binding]", "    option-h = 'focus right'", "    ctrl-option-j = 'fullscreen'"]
        assertEquals(try removeBindingFromLines(overridden, main("option-h")), [
            "[mode.main.binding]",
            "    ctrl-option-j = 'fullscreen'",
            "    option-h = 'disabled'",
        ])

        let inherited = ["start-at-login = true"]
        let result = try removeBindingFromLines(inherited, main("option-h"))
        assertEquals(result, ["start-at-login = true", "", "[mode.main.binding]", "    option-h = 'disabled'", ""])
        let combo = HotkeyBinding(.option, .h, []).descriptionWithKeyCode
        assertNil(parseConfig(result.joined(separator: "\n")).config.modes[mainModeId]?.bindings[combo])
        // Already disabled: nothing to do
        assertEquals(try removeBindingFromLines(result, main("option-h")), result)
    }

    func testRemoveDisablesAWorkspacesShorthandBinding() throws {
        let lines = ["[workspaces.names]", "    W = 'w'", "", "[mode.main.binding]", "    ctrl-option-j = 'fullscreen'"]

        let result = try removeBindingFromLines(lines, main("option-w"))

        assertEquals(result, ["[workspaces.names]", "    W = 'w'", "", "[mode.main.binding]", "    ctrl-option-j = 'fullscreen'", "    option-w = 'disabled'"])
        let parsed = parseConfig(result.joined(separator: "\n"))
        assertEquals(parsed.errors, [])
        assertNil(parsed.config.modes[mainModeId]?.bindings[HotkeyBinding(.option, .w, []).descriptionWithKeyCode])
    }

    // MARK: - TOML values

    func testCommandsValuePicksTheMostReadableString() throws {
        func roundTrip(_ commands: [String], file: StaticString = #filePath, line: UInt = #line) throws {
            let table = try TOMLTableForTests("value = \(tomlCommandsValue(commands))")
            XCTAssertEqual(table, commands, file: file, line: line)
        }
        assertEquals(tomlCommandsValue(["focus left"]), "'focus left'")
        assertEquals(tomlCommandsValue(["close", "mode main"]), "['close', 'mode main']")
        assertEquals(tomlCommandsValue(["summon-app \"It's\""]), #""summon-app \"It's\"""#)
        assertEquals(tomlCommandsValue(["exec-and-forget echo 'a'\necho b\n"]), "'''exec-and-forget echo 'a'\necho b\n'''")
        for commands in [
            ["focus left"],
            ["close", "mode main"],
            ["summon-app \"It's\""],
            ["exec-and-forget echo 'a'\necho b\n"],
            ["exec-and-forget echo '''a'''\n"],
            ["exec-and-forget \necho 'a'"],
            ["exec-and-forget echo\n'a'"],
            ["exec-and-forget printf 'a\\tb' \"c\"\t\u{1}\r\n"],
        ] {
            try roundTrip(commands)
        }
    }

    func testBindingCommandTextsReadsStringsAndArrays() {
        let toml = """
            [mode.main.binding]
                shift-cmd-k = ['close', 'mode main']
                option-h = 'focus left'
                option-j = 'disabled'
                option-k = []
            """
        assertEquals(bindingCommandTexts(inToml: toml, main("cmd-shift-k")), ["close", "mode main"])
        assertEquals(bindingCommandTexts(inToml: toml, main("option-h")), ["focus left"])
        assertNil(bindingCommandTexts(inToml: toml, main("option-j")))
        assertEquals(bindingCommandTexts(inToml: toml, main("option-k")), [])
        assertNil(bindingCommandTexts(inToml: toml, main("option-l")))
        assertNil(bindingCommandTexts(inToml: toml, BindingAddress(mode: "resize", binding: "option-h")))
        assertNil(bindingCommandTexts(inToml: "not toml [", main("option-h")))
    }
}

/// The value of `value` in `toml`, as the list of commands a binding would get
private func TOMLTableForTests(_ toml: String) throws -> [String] {
    try XCTUnwrap(bindingCommandTexts(inToml: "[mode.main.binding]\na = " + toml.dropFirst("value = ".count), BindingAddress(mode: mainModeId, binding: "a")))
}

@testable import AppBundle
import AppKit
import Common
import HotKey
import XCTest

@MainActor
final class ShortcutEditorTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        sessionCoordinator.setEnabled(true)
        activeMode = mainModeId
    }

    override func tearDown() async throws {
        setRecordingShortcut(false)
        sessionCoordinator.setEnabled(true)
        activeMode = mainModeId
    }

    private func problems(_ mode: String, _ binding: String, _ commands: [String]) -> ShortcutDraftProblems {
        shortcutDraftProblems(ShortcutDraft(mode: mode, binding: binding, commands: commands), existingModes: [mainModeId, "my mode"], keyMapping: keyNotationToKeyCode)
    }

    // MARK: - Draft checks

    func testAValidDraftHasNoProblems() {
        assertTrue(problems(mainModeId, "ctrl-option-k", ["focus left"]).isEmpty)
        assertTrue(problems(" go ", " a ", ["workspace A", "", "mode main"]).isEmpty)
        // An existing mode keeps its name, whatever it is
        assertTrue(problems("my mode", "a", ["close"]).isEmpty)
    }

    func testProblemsAreReportedByField() {
        assertEquals(problems("", "ctrl-option-k", ["close"]), ShortcutDraftProblems(mode: "Name the mode."))
        assertEquals(problems("new mode", "a", ["close"]), ShortcutDraftProblems(mode: "Use letters, digits, '-' and '_' in a mode name."))
        assertEquals(problems(mainModeId, "", ["close"]), ShortcutDraftProblems(binding: "Record a shortcut, or type one like ctrl-option-k."))
        assertEquals(problems(mainModeId, "hyper-k", ["close"]), ShortcutDraftProblems(binding: "'hyper-k' isn't a key Airlock can bind. Write it like ctrl-option-k."))
        assertEquals(problems(mainModeId, "a", ["", " \n"]), ShortcutDraftProblems(commands: [0: "Type a command, or pick one from the list."]))
        assertEquals(problems(mainModeId, "a", ["close", "nope"]).commands.keys.sorted(), [1])
        // One line, not the parser's whole usage text
        assertEquals(problems(mainModeId, "a", ["focus"]).commands[0]?.contains("\n"), false)
        // 'subscribe' parses, but a binding can't run it
        assertNotNil(parseCommand("list-apps").cmdOrNil)
        assertEquals(problems(mainModeId, "a", ["list-apps"]).commands.keys.sorted(), [0])
    }

    func testDraftDropsBlankCommandRows() {
        let draft = ShortcutDraft(mode: " go ", binding: " a ", commands: ["", "close", " "])
        assertEquals(draft.writtenCommands, ["close"])
        assertEquals(draft.address, BindingAddress(mode: "go", binding: "a"))
    }

    func testReplacesNamesWhatTheKeyAlreadyRuns() {
        config.modes = [mainModeId: Mode(bindings: Dictionary(uniqueKeysWithValues: parseBindings("""
            option-h = 'focus left'
            option-l = ['focus right', 'mode main']
            """).map { ($0.descriptionWithKeyCode, $0) }))]
        func replaces(_ binding: String, original: String?) -> String? {
            shortcutDraftReplaces(ShortcutDraft(mode: mainModeId, binding: binding, commands: ["close"]), original: original.map { BindingAddress(mode: mainModeId, binding: $0) })
        }

        assertEquals(replaces("option-h", original: nil), "focus left")
        assertEquals(replaces("option-l", original: "option-h"), "focus right, mode main")
        // The binding being edited isn't a conflict with itself, however its key is spelled
        assertNil(replaces("option-h", original: "option-h"))
        assertNil(replaces("shift-option-h", original: "option-shift-h"))
        assertNil(replaces("option-j", original: nil))
        assertNil(replaces("not a key", original: nil))
        // The same key in another mode is free
        assertNil(shortcutDraftReplaces(ShortcutDraft(mode: "resize", binding: "option-h", commands: ["close"]), original: nil))
    }

    // MARK: - Recording

    func testRecordedNotationOrdersModifiersLikeMacOs() {
        let mapping = keyNotationToKeyCode
        assertEquals(recordedBindingNotation(keyCode: UInt16(Key.k.carbonKeyCode), modifiers: [.command, .shift, .option, .control], keyMapping: mapping), "ctrl-option-shift-cmd-k")
        assertEquals(recordedBindingNotation(keyCode: UInt16(Key.k.carbonKeyCode), modifiers: [.option], keyMapping: mapping), "option-k")
        assertEquals(recordedBindingNotation(keyCode: UInt16(Key.return.carbonKeyCode), modifiers: [], keyMapping: mapping), "enter")
        assertEquals(recordedBindingNotation(keyCode: UInt16(Key.grave.carbonKeyCode), modifiers: [.command], keyMapping: mapping), "cmd-backtick")
        assertNil(recordedBindingNotation(keyCode: 0xFFFF, modifiers: [], keyMapping: mapping))
    }

    func testRecordedNotationParsesBackToTheSameKeyUnderEveryPreset() {
        for preset in [KeyMapping.Preset.qwerty, .dvorak, .colemak] {
            let mapping = KeyMapping(preset: preset, rawKeyNotationToKeyCode: [:]).resolve()
            for key in Set(mapping.values) {
                guard let notation = recordedBindingNotation(keyCode: UInt16(key.carbonKeyCode), modifiers: [.control, .command], keyMapping: mapping) else {
                    XCTFail("\(preset): no notation for \(key)")
                    continue
                }
                guard case .success(let (modifiers, parsedKey)) = parseBinding(notation, .emptyRoot, mapping) else {
                    XCTFail("\(preset): '\(notation)' doesn't parse")
                    continue
                }
                assertEquals(parsedKey, key)
                assertEquals(modifiers, [.control, .command])
            }
        }
    }

    func testNoHotkeyIsRegisteredWhileRecording() {
        let binding = HotkeyBinding([.control, .option, .command, .shift], .f19, [parseCommand("balance-sizes").cmdOrDie])
        config.modes = [mainModeId: Mode(bindings: [binding.descriptionWithKeyCode: binding])]
        defer { config.modes = [mainModeId: Mode(bindings: [:])] }
        assertEquals(bindingsToRegister(for: mainModeId).count, 1)

        setRecordingShortcut(true)
        assertTrue(isRecordingShortcut)
        assertEquals(bindingsToRegister(for: mainModeId).count, 0)
        // The bindings themselves are untouched: the menu and the Shortcuts list keep showing them
        assertEquals(hotkeyBindings(for: mainModeId).count, 1)

        setRecordingShortcut(false)
        XCTAssertFalse(isRecordingShortcut)
        assertEquals(bindingsToRegister(for: mainModeId).count, 1)
    }

    // MARK: - Suggestions

    func testEverySuggestionIsACommandABindingCanRun() {
        let suggestions = commandSuggestions(modes: ["resize", "my mode"], workspaces: ["1", "A", "two words"], apps: ["Safari", "It's \"odd\"", "Visual Studio Code"])
        for suggestion in suggestions {
            if case .failure(let message) = parseConfigCommand(suggestion.command) { XCTFail("\(suggestion.command): \(message)") }
        }
        assertEquals(Set(suggestions.map(\.id)).count, suggestions.count)
        let commands = suggestions.map(\.command)
        assertTrue(commands.contains("mode resize"))
        assertTrue(commands.contains("workspace A"))
        assertTrue(commands.contains("move-node-to-workspace 1"))
        assertTrue(commands.contains("summon-app \"Visual Studio Code\""))
        // Names that would need their own quoting are left out
        XCTAssertFalse(commands.contains { $0.contains("my mode") || $0.contains("two words") || $0.contains("odd") })
    }

    func testSuggestionSearchMatchesEveryWordInTitleOrCommand() {
        let suggestion = CommandSuggestion(title: "Move the window to workspace A", command: "move-node-to-workspace A")
        assertTrue(suggestion.matches("workspace move"))
        assertTrue(suggestion.matches("NODE"))
        XCTAssertFalse(suggestion.matches("workspace focus"))
    }

    // MARK: - List rows

    func testRowsCarryTheirBindingAndCollapsedRowsTheirMembers() {
        let shortcuts = keybindingShortcuts(parseBindings("""
            option-1 = 'workspace 1'
            option-2 = 'workspace 2'
            option-h = 'focus left'
            """))

        assertEquals(shortcuts.map { $0.binding?.descriptionWithKeyNotation }, [nil, "option-h"])
        assertEquals(shortcuts.map { $0.members.compactMap { $0.binding?.descriptionWithKeyNotation } }, [["option-1", "option-2"], []])
    }
}

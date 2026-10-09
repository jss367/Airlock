@testable import AppBundle
import AppKit
import Common
import HotKey
import XCTest

@MainActor
final class ConfigWriterTest: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - addBindingToLines / removeMatchingBindingLines

    func testAddBindingReplacesExistingRegardlessOfModifierOrder() throws {
        // "shift-cmd-k" should be replaced when adding "cmd-shift-k" (same modifiers, different text order)
        let lines = [
            "[mode.main.binding]",
            "    shift-cmd-k = 'exec-and-forget open -a \"OldApp\"'",
            "    option-h = 'focus left'",
        ]

        let result = try addBindingToLines(lines, key: "k", appName: "NewApp", modifierPrefix: [.command, .shift])

        // The old shift-cmd-k line should be gone
        let hasOldBinding = result.contains { $0.contains("OldApp") }
        XCTAssertFalse(hasOldBinding, "Old binding should have been removed")

        // The new binding should be present
        let hasNewBinding = result.contains { $0.contains("NewApp") }
        assertTrue(hasNewBinding)

        // option-h should be untouched
        let hasOptionH = result.contains { $0.contains("option-h") }
        assertTrue(hasOptionH)

        // There should be exactly one binding for key k with cmd+shift
        let kBindings = result.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.contains("-k") && trimmed.contains("=") && !trimmed.hasPrefix("#") && !trimmed.hasPrefix("[")
        }
        assertEquals(kBindings.count, 1)
    }

    func testAddBindingAppendsWhenNoMatchingKeyExists() throws {
        let lines = [
            "[mode.main.binding]",
            "    option-h = 'focus left'",
        ]

        let result = try addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: [.option, .control, .command, .shift])

        let hasSpotify = result.contains { $0.contains("Spotify") }
        assertTrue(hasSpotify)

        // Original binding should still be there
        let hasOptionH = result.contains { $0.contains("option-h") }
        assertTrue(hasOptionH)
    }

    func testAddBindingCreatesSection() throws {
        let lines = [
            "start-at-login = true",
        ]

        let result = try addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)

        let hasSectionHeader = result.contains { $0.contains("[mode.main.binding]") }
        assertTrue(hasSectionHeader)

        let hasBinding = result.contains { $0.contains("Spotify") }
        assertTrue(hasBinding)
    }

    func testAddBindingUnderColemakWritesKeyThatResolvesToClickedPhysicalKey() throws {
        let colemak = KeyMapping(preset: .colemak).resolve()
        // Under colemak, "e" is the physical K key and "k" is the physical N key
        let lines = [
            "[mode.main.binding]",
            "    option-e = 'summon-app \"OldApp\"'",
            "    option-k = 'focus left'",
        ]

        let result = try addBindingToLines(lines, key: "k", appName: "NewApp", modifierPrefix: .option, keyMapping: colemak)

        assertEquals(result, [
            "[mode.main.binding]",
            "    option-k = 'focus left'",
            "    option-e = 'summon-app \"NewApp\"'",
        ])
        let parsed = parseBinding("option-e", .emptyRoot, colemak).getOrNil()
        assertEquals(parsed?.1, .k)
    }

    func testAddBindingQuotesAMappedKeyNameThatIsNotABareKey() throws {
        var mapping = keyNotationToKeyCode
        mapping["k"] = .n
        mapping["foo.bar"] = .k

        let once = try addBindingToLines(["[mode.main.binding]"], key: "k", appName: "NewApp", modifierPrefix: .option, keyMapping: mapping)
        assertEquals(once, ["[mode.main.binding]", "    \"option-foo.bar\" = 'summon-app \"NewApp\"'"])
        assertEquals(parseBinding("option-foo.bar", .emptyRoot, mapping).getOrNil()?.1, .k)

        // Binding the same key again replaces the quoted line instead of adding a second one
        let twice = try addBindingToLines(once, key: "k", appName: "OtherApp", modifierPrefix: .option, keyMapping: mapping)
        assertEquals(twice, ["[mode.main.binding]", "    \"option-foo.bar\" = 'summon-app \"OtherApp\"'"])
    }

    func testAddBindingReplacesAQuotedKeyContainingEquals() throws {
        var mapping = keyNotationToKeyCode
        mapping["k"] = .n
        mapping["foo=bar"] = .k

        let once = try addBindingToLines(["[mode.main.binding]"], key: "k", appName: "NewApp", modifierPrefix: .option, keyMapping: mapping)
        let twice = try addBindingToLines(once, key: "k", appName: "OtherApp", modifierPrefix: .option, keyMapping: mapping)
        assertEquals(twice, ["[mode.main.binding]", "    \"option-foo=bar\" = 'summon-app \"OtherApp\"'"])
    }

    // MARK: - Binding line format

    func testBindingLineGeneratesSummonApp() {
        // Verify that the generated binding line uses summon-app format
        // We test this by parsing the expected output format
        let expectedLine = """
                option-ctrl-cmd-shift-s = 'summon-app "Spotify"'
            """
        let toml = """
            [mode.main.binding]
                \(expectedLine.trimmingCharacters(in: .whitespaces))
            """
        let (config, errors) = parseConfig(toml)
        assertEquals(errors, [])

        let hyper: NSEvent.ModifierFlags = [.option, .control, .command, .shift]
        let binding = config.modes[mainModeId]?.bindings.values.first {
            $0.modifiers == hyper && $0.keyCode == .s
        }
        assertNotNil(binding)
        XCTAssertTrue(binding?.commands.first?.args is SummonAppCmdArgs)
        assertEquals((binding?.commands.first?.args as? SummonAppCmdArgs)?.appName.val, "Spotify")
    }

    func testBindingLineWithApostropheInAppName() throws {
        try assertBindingRoundTrips(appName: "Test's App")
    }

    func testBindingLineWithDoubleQuoteInAppName() throws {
        try assertBindingRoundTrips(appName: "Say \"Hi\"")
    }

    func testBindingLineWithBackslashInAppName() throws {
        try assertBindingRoundTrips(appName: "Back\\slash's App")
    }

    func testBindingLineWithPlainAppName() throws {
        try assertBindingRoundTrips(appName: "Google Chrome")
    }

    func testAppNameWithBothQuoteCharactersIsRejected() {
        // splitArgs() has no escape sequences, so such a name cannot be written at all.
        XCTAssertFalse(canRepresentAppName("It's a \"Test\""))
        XCTAssertTrue(canRepresentAppName("Test's App"))
        XCTAssertTrue(canRepresentAppName("Say \"Hi\""))
    }

    /// Writes a binding for `appName`, then parses the resulting config and checks that
    /// the config is valid and the app name survived unchanged.
    private func assertBindingRoundTrips(appName: String) throws {
        let result = try addBindingToLines(["[mode.main.binding]"], key: "t", appName: appName, modifierPrefix: .option)

        let (config, errors) = parseConfig(result.joined(separator: "\n"))
        assertEquals(errors, [], additionalMsg: "Config with app name \(appName) failed to parse:\n\(result.joined(separator: "\n"))")

        let binding = config.modes[mainModeId]?.bindings[HotkeyBinding(.option, .t, []).descriptionWithKeyCode]
        assertNotNil(binding)
        assertEquals((binding?.commands.first?.args as? SummonAppCmdArgs)?.appName.val, appName)
    }

    // MARK: - Config parsing round-trip with summon-app

    func testSummonAppBindingRoundTrip() {
        let toml = """
            [mode.main.binding]
                option-ctrl-cmd-shift-i = 'summon-app "iTerm"'
                option-ctrl-cmd-shift-s = 'summon-app "Spotify"'
                option-ctrl-cmd-shift-c = 'summon-app "Google Chrome"'
            """
        let (config, errors) = parseConfig(toml)
        assertEquals(errors, [])

        let hyper: NSEvent.ModifierFlags = [.option, .control, .command, .shift]

        // Check all three bindings parse correctly
        for (key, expectedApp): (Key, String) in [(.i, "iTerm"), (.s, "Spotify"), (.c, "Google Chrome")] {
            let bindingKey = HotkeyBinding(hyper, key, []).descriptionWithKeyCode
            guard let binding = config.modes[mainModeId]?.bindings[bindingKey] else {
                XCTFail("Missing binding for \(key)")
                continue
            }
            XCTAssertTrue(binding.commands.first?.args is SummonAppCmdArgs)
            assertEquals((binding.commands.first?.args as? SummonAppCmdArgs)?.appName.val, expectedApp)
        }
    }

    func testSummonAppCoexistsWithWorkspaceBindings() {
        let toml = """
            [mode.main.binding]
                option-s = 'workspace S'
                option-ctrl-cmd-shift-s = 'summon-app "Spotify"'
            """
        let (config, errors) = parseConfig(toml)
        assertEquals(errors, [])

        // option-s should be workspace command
        let wsBinding = config.modes[mainModeId]?.bindings[
            HotkeyBinding(.option, .s, []).descriptionWithKeyCode,
        ]
        XCTAssertTrue(wsBinding?.commands.first is WorkspaceCommand)

        // hyper-s should be summon-app
        let hyper: NSEvent.ModifierFlags = [.option, .control, .command, .shift]
        let summonBinding = config.modes[mainModeId]?.bindings[
            HotkeyBinding(hyper, .s, []).descriptionWithKeyCode,
        ]
        XCTAssertTrue(summonBinding?.commands.first?.args is SummonAppCmdArgs)
    }

    // MARK: - Merge with defaults

    func testSummonAppBindingMergesWithDefaults() {
        // User adds a summon-app binding; default bindings should still be present
        let toml = """
            [mode.main.binding]
                option-ctrl-cmd-shift-s = 'summon-app "Spotify"'
            """
        let (config, errors) = parseConfig(toml)
        assertEquals(errors, [])

        // User's hyper-s binding should be present
        let hyper: NSEvent.ModifierFlags = [.option, .control, .command, .shift]
        let summonBinding = config.modes[mainModeId]?.bindings[
            HotkeyBinding(hyper, .s, []).descriptionWithKeyCode,
        ]
        assertNotNil(summonBinding)

        // Default bindings should also be present (e.g., option-h = 'focus left')
        let focusBinding = config.modes[mainModeId]?.bindings[
            HotkeyBinding(.option, .h, []).descriptionWithKeyCode,
        ]
        assertNotNil(focusBinding)
        XCTAssertTrue(focusBinding?.commands.first is FocusCommand)
    }

    // MARK: - Line manipulation edge cases

    func testAddBindingBeforeNextSection() throws {
        // Config has [mode.main.binding] followed by [mode.service.binding].
        // New binding should be inserted before the service section, not at end of file.
        let lines = [
            "[mode.main.binding]",
            "    option-h = 'focus left'",
            "[mode.service.binding]",
            "    esc = 'mode main'",
        ]
        let result = try addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)
        // The new binding should appear before [mode.service.binding]
        let serviceIndex = result.firstIndex(of: "[mode.service.binding]")!
        let newBindingIndex = result.firstIndex(where: { $0.contains("summon-app") && $0.contains("Spotify") })!
        XCTAssertTrue(newBindingIndex < serviceIndex, "New binding should be before the service section")
        // Original service binding should still be present
        XCTAssertTrue(result.contains("    esc = 'mode main'"))
    }

    func testAddBindingReplacesExistingWithDifferentCommand() throws {
        // Config has option-s = 'workspace S'. Adding binding for same key/modifier
        // with new app should replace it.
        let lines = [
            "[mode.main.binding]",
            "    option-s = 'workspace S'",
        ]
        let result = try addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)
        // Old binding should be gone
        XCTAssertFalse(result.contains { $0.contains("workspace S") })
        // New binding should be present
        XCTAssertTrue(result.contains { $0.contains("summon-app") && $0.contains("Spotify") })
    }

    func testAddBindingPreservesComments() throws {
        // Config has comments in the binding section. Adding a binding should not remove comment lines.
        let lines = [
            "[mode.main.binding]",
            "    # Focus bindings",
            "    option-h = 'focus left'",
            "    # Workspace bindings",
            "    option-1 = 'workspace 1'",
        ]
        let result = try addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)
        // Both comments should still be present
        XCTAssertTrue(result.contains("    # Focus bindings"))
        XCTAssertTrue(result.contains("    # Workspace bindings"))
        // Original bindings should still be present
        XCTAssertTrue(result.contains("    option-h = 'focus left'"))
        XCTAssertTrue(result.contains("    option-1 = 'workspace 1'"))
        // New binding should be present
        XCTAssertTrue(result.contains { $0.contains("summon-app") && $0.contains("Spotify") })
    }

    func testAddBindingReplacesMultiLineBinding() throws {
        let lines = [
            "[mode.main.binding]",
            "    option-enter = '''exec-and-forget osascript -e '",
            "    tell application \"Terminal\"",
            "        do script",
            "        activate",
            "    end tell'",
            "    '''",
            "    option-h = 'focus left'",
        ]
        let result = try addBindingToLines(lines, key: "enter", appName: "Ghostty", modifierPrefix: .option)
        assertEquals(result, [
            "[mode.main.binding]",
            "    option-h = 'focus left'",
            "    option-enter = 'summon-app \"Ghostty\"'",
        ])
        assertEquals(parseConfig(result.joined(separator: "\n")).errors.descriptions, [])
    }

    func testAddBindingInsertsAfterMultiLineValue() throws {
        // A multi-line value that is kept must stay whole, and its contents must not be read as a header
        let lines = [
            "[mode.main.binding]",
            "    option-t = [",
            "        'workspace T',",
            "        'exec-and-forget echo \"[not a header]\"',",
            "    ]",
        ]
        let result = try addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)
        assertEquals(result, lines + ["    option-s = 'summon-app \"Spotify\"'"])
        assertEquals(parseConfig(result.joined(separator: "\n")).errors.descriptions, [])
    }

    func testAddBindingSkipsBracketInsideMultiLineStringInArray() throws {
        // The `[` inside the multi-line string is not array syntax, so the array still ends at its `]`
        let mainSection = [
            "[mode.main.binding]",
            "    option-t = [",
            "        'workspace T',",
            "        '''exec-and-forget sh -c '",
            "        echo [",
            "        ''',",
            "    ]",
        ]
        let serviceSection = [
            "[mode.service.binding]",
            "    option-s = 'mode main'",
        ]
        let result = try addBindingToLines(mainSection + serviceSection, key: "s", appName: "Spotify", modifierPrefix: .option)
        assertEquals(result, mainSection + ["    option-s = 'summon-app \"Spotify\"'"] + serviceSection)
        assertEquals(parseConfig(result.joined(separator: "\n")).errors.descriptions, [])
    }

    func testAddBindingWithCommentedSectionHeaders() throws {
        let lines = [
            "[mode.main.binding] # my keys",
            "    option-s = 'workspace S'",
            "[mode.service.binding] # service keys",
            "    option-s = 'mode main'",
        ]
        let result = try addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)
        assertEquals(result, [
            "[mode.main.binding] # my keys",
            "    option-s = 'summon-app \"Spotify\"'",
            "[mode.service.binding] # service keys",
            "    option-s = 'mode main'",
        ])
    }

    func testAddBindingStopsAtHeaderWithHashInQuotedKey() throws {
        let lines = [
            "[mode.main.binding]",
            "    option-h = 'focus left'",
            "[mode.\"foo#bar\".binding]",
            "    option-s = 'mode main'",
        ]
        let result = try addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)
        assertEquals(result, [
            "[mode.main.binding]",
            "    option-h = 'focus left'",
            "    option-s = 'summon-app \"Spotify\"'",
            "[mode.\"foo#bar\".binding]",
            "    option-s = 'mode main'",
        ])
    }

    func testAddBindingToEmptyConfig() throws {
        // When there's no [mode.main.binding] section, it should be created
        let lines = [
            "enable-normalization-flatten-containers = true",
        ]
        let result = try addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)
        XCTAssertTrue(result.contains("[mode.main.binding]"))
        XCTAssertTrue(result.contains { $0.contains("summon-app") && $0.contains("Spotify") })
    }

    // MARK: - setTomlValueInLines

    func testSetTopLevelValueKeepsIndentAndComment() throws {
        let lines = [
            "config-version = 2",
            "prevent-focus-stealing = 'off' # was noisy",
            "",
            "[gaps]",
            "    inner.horizontal = 0",
        ]
        let result = try setTomlValueInLines(lines, table: nil, key: "prevent-focus-stealing", value: "'always'")
        assertEquals(result, [
            "config-version = 2",
            "prevent-focus-stealing = 'always' # was noisy",
            "",
            "[gaps]",
            "    inner.horizontal = 0",
        ])
        assertEquals(parseConfig(result.joined(separator: "\n")).config.preventFocusStealing, .always)
    }

    func testSetTopLevelValueAddsMissingKeyAfterLastTopLevelEntry() throws {
        let lines = [
            "config-version = 2",
            "",
            "[quick-switcher]",
            "    focus-workspace-on-mouse-click = true",
        ]
        let result = try setTomlValueInLines(lines, table: nil, key: "focus-workspace-on-mouse-click", value: "false")
        assertEquals(result, [
            "config-version = 2",
            "focus-workspace-on-mouse-click = false",
            "",
            "[quick-switcher]",
            "    focus-workspace-on-mouse-click = true",
        ])
    }

    func testSetTopLevelValueReplacesMultiLineValueWhole() throws {
        let lines = [
            "after-startup-command = [",
            "    'workspace 1',",
            "]",
            "[gaps]",
        ]
        let result = try setTomlValueInLines(lines, table: nil, key: "after-startup-command", value: "[]")
        assertEquals(result, ["after-startup-command = []", "[gaps]"])
    }

    func testSetTableValueInExistingSection() throws {
        let lines = [
            "[quick-switcher] # launcher",
            "    binding = 'option-space'",
            "    enabled = true",
            "[focus-flash]",
            "    enabled = true",
        ]
        let result = try setTomlValueInLines(lines, table: "focus-flash", key: "enabled", value: "false")
        assertEquals(result, [
            "[quick-switcher] # launcher",
            "    binding = 'option-space'",
            "    enabled = true",
            "[focus-flash]",
            "    enabled = false",
        ])
        let config = parseConfig(result.joined(separator: "\n")).config
        assertEquals(config.quickSwitcher.enabled, true)
        assertEquals(config.focusFlash.enabled, false)
    }

    func testSetTableValueAddsKeyToSectionWithoutIt() throws {
        let lines = [
            "[quick-switcher]",
            "  binding = 'option-space'",
            "",
            "[gaps]",
        ]
        let result = try setTomlValueInLines(lines, table: "quick-switcher", key: "enabled", value: "false")
        assertEquals(result, [
            "[quick-switcher]",
            "  binding = 'option-space'",
            "  enabled = false",
            "",
            "[gaps]",
        ])
    }

    func testSetTableValueAppendsMissingTable() throws {
        let lines = ["config-version = 2", ""]
        let result = try setTomlValueInLines(lines, table: "focus-flash", key: "enabled", value: "false")
        assertEquals(result, ["config-version = 2", "", "[focus-flash]", "    enabled = false", ""])
        assertEquals(parseConfig(result.joined(separator: "\n")).config.focusFlash.enabled, false)
    }

    func testSetTableValueUsesDottedKeysWhenTableHasNoHeader() throws {
        let lines = ["quick-switcher . enabled = true", "quick-switcher.binding = 'option-space'"]
        let result = try setTomlValueInLines(lines, table: "quick-switcher", key: "enabled", value: "false")
        assertEquals(result, ["quick-switcher.enabled = false", "quick-switcher.binding = 'option-space'"])
        assertEquals(parseConfig(result.joined(separator: "\n")).config.quickSwitcher.enabled, false)
    }

    func testSetValueMatchesQuotedKeys() throws {
        let lines = [
            "\"start-at-login\" = false",
            "\"quick-switcher\" . 'enabled' = true",
            "[\"focus-flash\"]",
            "    'enabled' = true",
        ]
        var result = try setTomlValueInLines(lines, table: nil, key: "start-at-login", value: "true")
        result = try setTomlValueInLines(result, table: "quick-switcher", key: "enabled", value: "false")
        result = try setTomlValueInLines(result, table: "focus-flash", key: "enabled", value: "false")
        assertEquals(result, [
            "start-at-login = true",
            "quick-switcher.enabled = false",
            "[\"focus-flash\"]",
            "    enabled = false",
        ])
    }

    func testSetTableValueRefusesInlineTable() {
        let lines = ["quick-switcher = { enabled = true }"]
        XCTAssertThrowsError(try setTomlValueInLines(lines, table: "quick-switcher", key: "enabled", value: "false"))
    }

    // MARK: - Edit verification

    func testSetTableValueRefusesArrayOfTables() {
        // The line edit reads `[[focus-flash]]` as a table header, so the result parses but means something else
        let lines = ["[[focus-flash]]", "    enabled = true"]
        XCTAssertThrowsError(try setTomlValueInLines(lines, table: "focus-flash", key: "enabled", value: "false")) {
            assertEquals($0.localizedDescription, ConfigWriterError.unsupportedEdit("focus-flash.enabled").localizedDescription)
        }
    }

    func testAddBindingRefusesBindingsWrittenAsDottedKeys() {
        // Appending a [mode.main.binding] header would redefine the table the dotted key already created
        let lines = ["[mode.main]", "    binding.option-s = 'workspace S'"]
        XCTAssertThrowsError(try addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)) {
            assertEquals($0.localizedDescription, ConfigWriterError.unsupportedEdit("mode.main.binding.option-s").localizedDescription)
        }
    }

    func testAddBindingRefusesInlineBindingTable() {
        let lines = ["[mode.main]", "    binding = { option-h = 'focus left' }"]
        XCTAssertThrowsError(try addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option))
    }

    func testEditRefusesConfigWithSyntaxError() {
        let lines = ["start-at-login = ", "[focus-flash]"]
        XCTAssertThrowsError(try setTomlValueInLines(lines, table: "focus-flash", key: "enabled", value: "false")) {
            guard case ConfigWriterError.invalidConfig = $0 else { return XCTFail("Unexpected error \($0)") }
        }
    }

    func testAddBindingToDefaultConfigIsVerified() throws {
        let lines = try readConfigLines(from: defaultConfigUrl).lines
        let result = try addBindingToLines(lines, key: "h", appName: "Spotify", modifierPrefix: .option)
        let binding = parseConfig(result.joined(separator: "\n")).config.modes[mainModeId]?.bindings[HotkeyBinding(.option, .h, []).descriptionWithKeyCode]
        assertEquals((binding?.commands.first?.args as? SummonAppCmdArgs)?.appName.val, "Spotify")
    }

    func testSetValueInDefaultConfigIsVerified() throws {
        let lines = try readConfigLines(from: defaultConfigUrl).lines
        for (table, key) in [(nil, "start-at-login"), ("quick-switcher", "enabled"), ("focus-flash", "enabled")] {
            _ = try setTomlValueInLines(lines, table: table, key: key, value: "true")
        }
    }

    func testSetTableValueIgnoresKeysInOtherSections() throws {
        let lines = [
            "[mode.main.binding]",
            "    enabled = 'workspace E'",
            "[focus-flash]",
            "    width = 6.0",
        ]
        let result = try setTomlValueInLines(lines, table: "focus-flash", key: "enabled", value: "false")
        assertEquals(result, [
            "[mode.main.binding]",
            "    enabled = 'workspace E'",
            "[focus-flash]",
            "    width = 6.0",
            "    enabled = false",
        ])
    }

    func testEditSucceedsWhenConfigContainsNan() throws {
        let lines = ["[focus-flash]", "    width = nan", "    enabled = true"]
        let result = try setTomlValueInLines(lines, table: "focus-flash", key: "enabled", value: "false")
        assertEquals(result, ["[focus-flash]", "    width = nan", "    enabled = false"])
    }

    func testSetConfigValueWritesThroughSymlink() throws {
        let target = tempDir.appending(component: "real.toml")
        let link = tempDir.appending(component: "link.toml")
        try "start-at-login = false\n".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let lines = try String(contentsOf: link, encoding: .utf8).components(separatedBy: "\n")
        try writeConfigLines(setTomlValueInLines(lines, table: nil, key: "start-at-login", value: "true"), to: link)
        assertEquals(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        assertEquals(try String(contentsOf: target, encoding: .utf8), "start-at-login = true\n")
    }

    func testCrlfConfigKeepsLineEndingsAndFindsTable() throws {
        let url = tempDir.appending(component: "crlf.toml")
        try "[quick-switcher]\r\n    enabled = true\r\n".write(to: url, atomically: true, encoding: .utf8)
        let config = try readConfigLines(from: url)
        assertEquals(config.lines, ["[quick-switcher]", "    enabled = true", ""])
        let result = try setTomlValueInLines(config.lines, table: "quick-switcher", key: "enabled", value: "false")
        try writeConfigLines(result, to: url, separator: config.separator)
        assertEquals(try String(contentsOf: url, encoding: .utf8), "[quick-switcher]\r\n    enabled = false\r\n")
    }
}

@testable import AppBundle
import Common
import HotKey
import XCTest

@MainActor
final class ConfigWriterTest: XCTestCase {
    private var tempDir: URL!
    private var tempConfigURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        tempConfigURL = tempDir.appending(component: ".airlock.toml")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - addBindingToLines / removeMatchingBindingLines

    func testAddBindingReplacesExistingRegardlessOfModifierOrder() {
        // "shift-cmd-k" should be replaced when adding "cmd-shift-k" (same modifiers, different text order)
        let lines = [
            "[mode.main.binding]",
            "    shift-cmd-k = 'exec-and-forget open -a \"OldApp\"'",
            "    option-h = 'focus left'",
        ]

        let result = addBindingToLines(lines, key: "k", appName: "NewApp", modifierPrefix: [.command, .shift])

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

    func testAddBindingAppendsWhenNoMatchingKeyExists() {
        let lines = [
            "[mode.main.binding]",
            "    option-h = 'focus left'",
        ]

        let result = addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: [.option, .control, .command, .shift])

        let hasSpotify = result.contains { $0.contains("Spotify") }
        assertTrue(hasSpotify)

        // Original binding should still be there
        let hasOptionH = result.contains { $0.contains("option-h") }
        assertTrue(hasOptionH)
    }

    func testAddBindingCreatesSection() {
        let lines = [
            "start-at-login = true",
        ]

        let result = addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)

        let hasSectionHeader = result.contains { $0.contains("[mode.main.binding]") }
        assertTrue(hasSectionHeader)

        let hasBinding = result.contains { $0.contains("Spotify") }
        assertTrue(hasBinding)
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

    func testBindingLineWithQuoteInAppName() {
        // Exercise addBindingToLines with a single-quote in the app name
        let lines = [
            "[mode.main.binding]",
        ]

        let result = addBindingToLines(lines, key: "t", appName: "Test's App", modifierPrefix: .option)

        // The output line should contain the escaped app name
        let bindingLine = result.first { $0.contains("option-t") }
        assertNotNil(bindingLine)
        // The single quote should be escaped for shell: ' becomes '\''
        XCTAssertTrue(bindingLine!.contains("Test'\\''s App"), "Expected escaped quote in: \(bindingLine!)")
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
            HotkeyBinding(.option, .s, []).descriptionWithKeyCode
        ]
        XCTAssertTrue(wsBinding?.commands.first is WorkspaceCommand)

        // hyper-s should be summon-app
        let hyper: NSEvent.ModifierFlags = [.option, .control, .command, .shift]
        let summonBinding = config.modes[mainModeId]?.bindings[
            HotkeyBinding(hyper, .s, []).descriptionWithKeyCode
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
            HotkeyBinding(hyper, .s, []).descriptionWithKeyCode
        ]
        assertNotNil(summonBinding)

        // Default bindings should also be present (e.g., option-h = 'focus left')
        let focusBinding = config.modes[mainModeId]?.bindings[
            HotkeyBinding(.option, .h, []).descriptionWithKeyCode
        ]
        assertNotNil(focusBinding)
        XCTAssertTrue(focusBinding?.commands.first is FocusCommand)
    }
}

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

    func testAddBindingBeforeNextSection() {
        // Config has [mode.main.binding] followed by [mode.service.binding].
        // New binding should be inserted before the service section, not at end of file.
        let lines = [
            "[mode.main.binding]",
            "    option-h = 'focus left'",
            "[mode.service.binding]",
            "    esc = 'mode main'",
        ]
        let result = addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)
        // The new binding should appear before [mode.service.binding]
        let serviceIndex = result.firstIndex(of: "[mode.service.binding]")!
        let newBindingIndex = result.firstIndex(where: { $0.contains("summon-app") && $0.contains("Spotify") })!
        XCTAssertTrue(newBindingIndex < serviceIndex, "New binding should be before the service section")
        // Original service binding should still be present
        XCTAssertTrue(result.contains("    esc = 'mode main'"))
    }

    func testAddBindingReplacesExistingWithDifferentCommand() {
        // Config has option-s = 'workspace S'. Adding binding for same key/modifier
        // with new app should replace it.
        let lines = [
            "[mode.main.binding]",
            "    option-s = 'workspace S'",
        ]
        let result = addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)
        // Old binding should be gone
        XCTAssertFalse(result.contains { $0.contains("workspace S") })
        // New binding should be present
        XCTAssertTrue(result.contains { $0.contains("summon-app") && $0.contains("Spotify") })
    }

    func testAddBindingPreservesComments() {
        // Config has comments in the binding section. Adding a binding should not remove comment lines.
        let lines = [
            "[mode.main.binding]",
            "    # Focus bindings",
            "    option-h = 'focus left'",
            "    # Workspace bindings",
            "    option-1 = 'workspace 1'",
        ]
        let result = addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)
        // Both comments should still be present
        XCTAssertTrue(result.contains("    # Focus bindings"))
        XCTAssertTrue(result.contains("    # Workspace bindings"))
        // Original bindings should still be present
        XCTAssertTrue(result.contains("    option-h = 'focus left'"))
        XCTAssertTrue(result.contains("    option-1 = 'workspace 1'"))
        // New binding should be present
        XCTAssertTrue(result.contains { $0.contains("summon-app") && $0.contains("Spotify") })
    }

    func testAddBindingToEmptyConfig() {
        // When there's no [mode.main.binding] section, it should be created
        let lines = [
            "enable-normalization-flatten-containers = true",
        ]
        let result = addBindingToLines(lines, key: "s", appName: "Spotify", modifierPrefix: .option)
        XCTAssertTrue(result.contains("[mode.main.binding]"))
        XCTAssertTrue(result.contains { $0.contains("summon-app") && $0.contains("Spotify") })
    }
}

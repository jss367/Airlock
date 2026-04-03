@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class ConfigWriterTest: XCTestCase {
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

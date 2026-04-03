@testable import AppBundle
import Common
import HotKey
import XCTest

@MainActor
final class BindingAnalyzerTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
    }

    // MARK: - classifyBinding via analyzeBindings

    func testSummonAppBindingClassifiedAsAppLauncher() {
        let (testConfig, errors) = parseConfig(
            """
            [mode.main.binding]
                option-s = 'summon-app "Spotify"'
            """,
        )
        assertEquals(errors, [])
        config = testConfig

        let bindings = analyzeBindings(modifierPrefix: .option)
        guard case .appLauncher(let appName, _) = bindings["s"] else {
            XCTFail("Expected appLauncher for option-s, got \(String(describing: bindings["s"]))")
            return
        }
        assertEquals(appName, "Spotify")
    }

    func testExecOpenAppBindingClassifiedAsAppLauncher() {
        let (testConfig, errors) = parseConfig(
            """
            [mode.main.binding]
                option-g = 'exec-and-forget open -a "GitHub Desktop"'
            """,
        )
        assertEquals(errors, [])
        config = testConfig

        let bindings = analyzeBindings(modifierPrefix: .option)
        guard case .appLauncher(let appName, _) = bindings["g"] else {
            XCTFail("Expected appLauncher for option-g, got \(String(describing: bindings["g"]))")
            return
        }
        assertEquals(appName, "GitHub Desktop")
    }

    func testOsascriptActivateClassifiedAsAppLauncher() {
        let (testConfig, errors) = parseConfig(
            """
            [mode.main.binding]
                option-s = '''exec-and-forget osascript -e '
                    tell application "Spotify" to activate'
                '''
            """,
        )
        assertEquals(errors, [])
        config = testConfig

        let bindings = analyzeBindings(modifierPrefix: .option)
        guard case .appLauncher(let appName, _) = bindings["s"] else {
            XCTFail("Expected appLauncher for option-s, got \(String(describing: bindings["s"]))")
            return
        }
        assertEquals(appName, "Spotify")
    }

    func testOsascriptKeystrokeClassifiedAsOtherCommand() {
        // Note: the modifier regex expects curly braces, e.g. using {command down}
        let (testConfig, errors) = parseConfig(
            """
            [mode.main.binding]
                option-f = '''exec-and-forget osascript -e '
                    tell application "Firefox" to activate
                    tell application "System Events" to keystroke "n" using {command down}'
                '''
            """,
        )
        assertEquals(errors, [])
        config = testConfig

        let bindings = analyzeBindings(modifierPrefix: .option)
        guard case .otherCommand(let desc) = bindings["f"] else {
            XCTFail("Expected otherCommand for option-f, got \(String(describing: bindings["f"]))")
            return
        }
        XCTAssertTrue(desc.contains("Firefox"))
        XCTAssertTrue(desc.contains("⌘"))
    }

    func testNonExecBindingClassifiedAsOtherCommand() {
        let (testConfig, errors) = parseConfig(
            """
            [mode.main.binding]
                option-h = 'focus left'
            """,
        )
        assertEquals(errors, [])
        config = testConfig

        let bindings = analyzeBindings(modifierPrefix: .option)
        guard case .otherCommand = bindings["h"] else {
            XCTFail("Expected otherCommand for option-h, got \(String(describing: bindings["h"]))")
            return
        }
    }

    // MARK: - Modifier filtering

    func testAnalyzeBindingsFiltersbyModifier() {
        let (testConfig, errors) = parseConfig(
            """
            [mode.main.binding]
                option-s = 'workspace S'
                ctrl-option-shift-cmd-s = 'summon-app "Spotify"'
            """,
        )
        assertEquals(errors, [])
        config = testConfig

        let optionBindings = analyzeBindings(modifierPrefix: .option)
        guard case .otherCommand = optionBindings["s"] else {
            XCTFail("Expected otherCommand for option-s")
            return
        }

        let hyperBindings = analyzeBindings(modifierPrefix: [.option, .control, .command, .shift])
        guard case .appLauncher(let appName, _) = hyperBindings["s"] else {
            XCTFail("Expected appLauncher for hyper-s")
            return
        }
        assertEquals(appName, "Spotify")
    }

    // MARK: - extractAppName edge cases

    func testOpenAppWithSingleQuotes() {
        let (testConfig, errors) = parseConfig(
            """
            [mode.main.binding]
                option-g = "exec-and-forget open -a 'GitHub Desktop'"
            """,
        )
        assertEquals(errors, [])
        config = testConfig

        let bindings = analyzeBindings(modifierPrefix: .option)
        guard case .appLauncher(let appName, _) = bindings["g"] else {
            XCTFail("Expected appLauncher for option-g, got \(String(describing: bindings["g"]))")
            return
        }
        assertEquals(appName, "GitHub Desktop")
    }

    func testOpenAppWithDotAppSuffix() {
        let (testConfig, errors) = parseConfig(
            """
            [mode.main.binding]
                option-s = 'exec-and-forget open -a "Spotify.app"'
            """,
        )
        assertEquals(errors, [])
        config = testConfig

        let bindings = analyzeBindings(modifierPrefix: .option)
        guard case .appLauncher(let appName, _) = bindings["s"] else {
            XCTFail("Expected appLauncher for option-s, got \(String(describing: bindings["s"]))")
            return
        }
        assertEquals(appName, "Spotify")
    }

    func testOpenAppUnquoted() {
        let (testConfig, errors) = parseConfig(
            """
            [mode.main.binding]
                option-s = 'exec-and-forget open -a Safari'
            """,
        )
        assertEquals(errors, [])
        config = testConfig

        let bindings = analyzeBindings(modifierPrefix: .option)
        guard case .appLauncher(let appName, _) = bindings["s"] else {
            XCTFail("Expected appLauncher for option-s, got \(String(describing: bindings["s"]))")
            return
        }
        assertEquals(appName, "Safari")
    }
}

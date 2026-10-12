@testable import AppBundle
import Carbon
import Common
import XCTest

@MainActor
final class ConfigReadTest: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        setUpWorkspacesForTests()
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try FileManager.default.removeItem(at: directory)
        setUpWorkspacesForTests()
    }

    func testExplicitMissingPathIsNotReplacedWithDefaults() {
        let url = directory.appending(path: "missing.toml")
        XCTAssertEqual(findCustomConfigUrl(configLocation: url.path).urlOrNil, url)
        assertReadFailure(url)
    }

    func testDirectoryAndInvalidEncodingAreReadFailures() throws {
        assertReadFailure(directory)
        let url = directory.appending(path: "invalid.toml")
        try Data([0xFF, 0xFE, 0xFF]).write(to: url)
        assertReadFailure(url)
    }

    func testFailedReloadPreservesActiveConfiguration() async throws {
        config.accordionPadding = 123
        let previousUrl = configUrl
        let previousMode = activeMode
        var args = ReloadConfigCmdArgs(rawArgs: [])
        args.noGui = true
        var output = ""
        let result = try await reloadConfig(args: args, forceConfigUrl: directory.appending(path: "missing.toml"), stdout: &output)
        XCTAssertFalse(result)
        XCTAssertEqual(config.accordionPadding, 123)
        XCTAssertEqual(configUrl, previousUrl)
        XCTAssertEqual(activeMode, previousMode)
        XCTAssertTrue(output.contains("Failed to read"))
    }

    func testReadableConfigStillParsesAndSyntaxErrorsStillReport() throws {
        let url = directory.appending(path: "config.toml")
        try "accordion-padding = 42".write(to: url, atomically: true, encoding: .utf8)
        let (parsed, actualUrl) = try readConfig(forceConfigUrl: url).get()
        XCTAssertEqual(parsed.accordionPadding, 42)
        XCTAssertEqual(actualUrl, url)
        try "accordion-padding = [".write(to: url, atomically: true, encoding: .utf8)
        guard case .failure(let message) = readConfig(forceConfigUrl: url) else {
            return XCTFail("Expected a syntax error")
        }
        XCTAssertTrue(message.contains("Failed to parse"))
    }

    func testFallbackAfterFailureKeepsLoginItemAndWatchesUserConfig() async throws {
        // Paused, so the reloads register no global hotkeys
        TrayMenuModel.shared.isEnabled = false
        activeMode = nil
        defer {
            TrayMenuModel.shared.isEnabled = true
            activeMode = mainModeId
            failedUserConfigUrl = nil
            syncConfigFileWatcher()
        }
        let userUrl = directory.appending(path: "airlock.toml")
        try "accordion-padding = [".write(to: userUrl, atomically: true, encoding: .utf8)
        config.accordionPadding = 123
        let syncs = startAtLoginSyncCountForTests
        var args = ReloadConfigCmdArgs(rawArgs: [])
        args.noGui = true
        var output = ""

        let fallbackLoaded = try await loadDefaultConfigAfterFailure(userConfigUrl: userUrl, stdout: &output)
        XCTAssertTrue(fallbackLoaded)
        XCTAssertEqual(config.accordionPadding, defaultConfig.accordionPadding)
        XCTAssertFalse(config.autoReloadConfig)
        XCTAssertEqual(startAtLoginSyncCountForTests, syncs)
        XCTAssertEqual(watchedConfigUrl, userUrl)

        // Still broken: keep watching it
        let brokenLoaded = try await reloadConfig(args: args, forceConfigUrl: userUrl, stdout: &output)
        XCTAssertFalse(brokenLoaded)
        XCTAssertEqual(watchedConfigUrl, userUrl)

        // Once a config loads, its own settings decide. A separate file, so the watcher doesn't fire
        let fixedUrl = directory.appending(path: "fixed.toml")
        try "accordion-padding = 42".write(to: fixedUrl, atomically: true, encoding: .utf8)
        let fixedLoaded = try await reloadConfig(args: args, forceConfigUrl: fixedUrl, stdout: &output)
        XCTAssertTrue(fixedLoaded)
        XCTAssertEqual(config.accordionPadding, 42)
        XCTAssertEqual(startAtLoginSyncCountForTests, syncs + 1)
        XCTAssertNil(watchedConfigUrl)
    }

    func testQuickSwitcherKeyMovedToBindingWorksAfterReload() async throws {
        TrayMenuModel.shared.isEnabled = true
        activeMode = mainModeId
        config.quickSwitcher.enabled = true
        config.quickSwitcher.binding = "option-space"
        registerQuickSwitcherHotkey()
        defer {
            resetHotKeys()
            config.quickSwitcher.enabled = false
            registerQuickSwitcherHotkey()
        }
        assertEquals(isQuickSwitcherHotkeyRegistered, true)
        let url = directory.appending(path: "airlock.toml")
        try """
            [quick-switcher]
                enabled = false
            [mode.main.binding]
                option-space = 'workspace 1'
            """.write(to: url, atomically: true, encoding: .utf8)
        var args = ReloadConfigCmdArgs(rawArgs: [])
        args.noGui = true
        var output = ""
        let loaded = try await reloadConfig(args: args, forceConfigUrl: url, stdout: &output)
        XCTAssertTrue(loaded, output)

        // macOS refuses a second registration of a key this process holds. The probe only gets
        // option-space if the binding's registration failed
        var probe: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(optionKey), EventHotKeyID(signature: 0x5052_4F42, id: 1), GetEventDispatcherTarget(), 0, &probe,
        )
        if let probe { UnregisterEventHotKey(probe) }
        XCTAssertEqual(status, OSStatus(eventHotKeyExistsErr))
    }

    private func assertReadFailure(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let message) = readConfig(forceConfigUrl: url) else {
            return XCTFail("Unreadable config must not succeed with defaults", file: file, line: line)
        }
        XCTAssertTrue(message.contains("Failed to read"), file: file, line: line)
        XCTAssertTrue(message.contains(url.path), file: file, line: line)
    }
}

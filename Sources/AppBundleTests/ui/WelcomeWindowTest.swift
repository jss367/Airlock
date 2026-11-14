@testable import AppBundle
import Common
import XCTest

@MainActor
final class WelcomeWindowTest: XCTestCase {
    private let suiteName = "airlock-welcome-test-\(UUID().uuidString)"
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    override func tearDown() async throws { defaults.removePersistentDomain(forName: suiteName) }

    func testStepsKeepTheirOrderAndSkipWhatDoesNotApply() {
        assertEquals(
            welcomeSteps(needsPermission: true, dockSettingNeedsAttention: true, showBasics: true),
            [.permission, .dockSetting, .basics],
        )
        assertEquals(welcomeSteps(needsPermission: false, dockSettingNeedsAttention: true, showBasics: false), [.dockSetting])
        assertEquals(welcomeSteps(needsPermission: false, dockSettingNeedsAttention: false, showBasics: false), [])
    }

    func testDockSettingIsIgnoredOnceTheUserSaysSo() {
        XCTAssertTrue(autoSwooshNeedsAttention(defaults, isEnabled: true))
        XCTAssertFalse(autoSwooshNeedsAttention(defaults, isEnabled: false))
        ignoreAutoSwoosh(defaults)
        XCTAssertFalse(autoSwooshNeedsAttention(defaults, isEnabled: true))
    }

    func testShortcutsOfDefaultConfig() {
        assertEquals(welcomeShortcuts(defaultConfig), [
            WelcomeShortcut(title: "Switch to workspace 1", keys: "option-1", detail: "⌥2 for workspace 2, and so on"),
            WelcomeShortcut(title: "Move the focused window to workspace 1", keys: "option-shift-1", detail: "⌥⇧2 for workspace 2, and so on"),
            WelcomeShortcut(title: "Open the quick switcher", keys: "option-space", detail: "Search workspaces and windows, then jump to one"),
        ])
    }

    func testShortcutsFollowTheConfig() {
        let (config, errors) = parseConfig(
            """
            config-version = 2
            persistent-workspaces = ['Web', 'Mail']
            [quick-switcher]
                binding = 'ctrl-cmd-p'
            [mode.main.binding]
                option-1 = 'disabled'
                option-2 = 'disabled'
                option-3 = 'disabled'
                option-4 = 'disabled'
                option-5 = 'disabled'
                option-6 = 'disabled'
                option-7 = 'disabled'
                option-8 = 'disabled'
                option-9 = 'disabled'
                cmd-ctrl-m = 'workspace Mail'
                cmd-ctrl-w = 'workspace Web'
                option-tab = ['workspace Web', 'layout tiles']
            """,
        )
        assertEquals(errors, [])
        let shortcuts = welcomeShortcuts(config)
        assertEquals(shortcuts[0], WelcomeShortcut(title: "Switch to workspace Web", keys: "cmd-ctrl-w", detail: "⌃⌘M for workspace Mail"))
        assertEquals(shortcuts[1].keys, "option-shift-1")
        assertEquals(shortcuts[2].keys, "ctrl-cmd-p")
    }

    func testShortcutsThatAreNotBound() {
        var config = defaultConfig
        config.modes = [mainModeId: Mode(bindings: [:])]
        config.quickSwitcher.enabled = false
        assertEquals(welcomeShortcuts(config).map(\.keys), [nil, nil, nil])
        assertEquals(welcomeShortcuts(config)[0].title, "Switch to a workspace")

        config = defaultConfig
        config.enableKeyboardShortcuts = false
        assertEquals(welcomeShortcuts(config).map(\.keys), [nil, nil, "option-space"])
        assertEquals(welcomeShortcuts(config)[1].detail, "Keyboard shortcuts are turned off.")
    }

    func testShortcutKeyLabels() {
        assertEquals(shortcutKeyLabels("option-shift-1"), ["⌥", "⇧", "1"])
        assertEquals(shortcutKeyLabels("cmd-shift-ctrl-option-a"), ["⌃", "⌥", "⇧", "⌘", "A"])
        assertEquals(shortcutKeyLabels("option-space"), ["⌥", "Space"])
        assertEquals(shortcutKeyLabels("option-minus"), ["⌥", "−"])
        assertEquals(shortcutKeyLabels("f1"), ["F1"])
        assertEquals(shortcutSymbols("option-tab"), "⌥⇥")
    }

    func testPermissionStepMovesOnOnceAccessIsGranted() async {
        let (granted, grant) = AsyncStream.makeStream(of: Void.self)
        let model = WelcomeModel(defaults: defaults) {
            for await _ in granted { return }
            throw CancellationError()
        }
        var finished = false
        model.onFinish = { finished = true }

        model.start([.permission, .basics])
        for _ in 0 ..< 10 { await Task.yield() }
        assertEquals(model.step, .permission)
        XCTAssertFalse(defaults.bool(forKey: "airlock-welcome-shown"))

        grant.yield()
        for _ in 0 ..< 1000 where model.step == .permission { await Task.yield() }
        assertEquals(model.step, .basics)
        XCTAssertTrue(defaults.bool(forKey: "airlock-welcome-shown"))
        XCTAssertFalse(finished)

        model.advance()
        assertEquals(model.step, nil)
        XCTAssertTrue(finished)
    }

    func testClosingTheWindowStopsWaitingForAccess() async {
        let (granted, grant) = AsyncStream.makeStream(of: Void.self)
        let model = WelcomeModel(defaults: defaults) {
            for await _ in granted { return }
            throw CancellationError()
        }
        var finished = false
        model.onFinish = { finished = true }

        model.start([.permission, .basics])
        model.reset()
        grant.yield()
        for _ in 0 ..< 10 { await Task.yield() }
        assertEquals(model.step, nil)
        XCTAssertFalse(finished)
        XCTAssertFalse(defaults.bool(forKey: "airlock-welcome-shown"))
    }
}

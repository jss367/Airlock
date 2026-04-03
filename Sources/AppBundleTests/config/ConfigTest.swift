@testable import AppBundle
import Common
import XCTest

@MainActor
final class ConfigTest: XCTestCase {
    func testParseI3Config() {
        let toml = try! String(contentsOf: projectRoot.appending(component: "docs/config-examples/i3-like-config-example.toml"), encoding: .utf8)
        let (i3Config, errors) = parseConfig(toml)
        assertEquals(errors, [])
        assertEquals(i3Config.execConfig, defaultConfig.execConfig)
        assertEquals(i3Config.enableNormalizationFlattenContainers, false)
        assertEquals(i3Config.enableNormalizationOppositeOrientationForNestedContainers, false)
    }

    func testParseDefaultConfig() {
        let toml = try! String(contentsOf: projectRoot.appending(component: "docs/config-examples/default-config.toml"), encoding: .utf8)
        let (_, errors) = parseConfig(toml)
        assertEquals(errors, [])
    }

    func testConfigVersionOutOfBounds() {
        let (_, errors) = parseConfig(
            """
            config-version = 0
            """,
        )
        assertEquals(errors.descriptions, ["config-version: Must be in [1, 2] range"])
    }

    func testDuplicatedPersistentWorkspaces() {
        let (_, errors) = parseConfig(
            """
            config-version = 2
            persistent-workspaces = ['a', 'a']
            """,
        )
        assertEquals(errors.descriptions, ["persistent-workspaces: Contains duplicated workspace names"])
    }

    func testPersistentWorkspacesAreAvailableOnlySinceVersion2() {
        let (_, errors) = parseConfig(
            """
            persistent-workspaces = ['a']
            """,
        )
        assertEquals(errors.descriptions, ["persistent-workspaces: This config option is only available since \'config-version = 2\'"])
    }

    func testQueryCantBeUsedInConfig() {
        let (_, errors) = parseConfig(
            """
            [mode.main.binding]
                option-a = 'list-apps'
            """,
        )
        XCTAssertTrue(errors.descriptions.singleOrNil()?.contains("cannot be used in config") == true)
    }

    func testDropBindings() {
        let (config, errors) = parseConfig(
            """
            mode.main = {}
            """,
        )
        assertEquals(errors, [])
        // With merge-with-defaults, an empty main mode inherits all default bindings
        XCTAssertTrue(config.modes[mainModeId]?.bindings.isEmpty == false)
        assertEquals(config.modes[mainModeId]?.bindings, defaultConfig.modes[mainModeId]?.bindings)
    }

    func testParseMode() {
        let (config, errors) = parseConfig(
            """
            [mode.main.binding]
                option-h = 'focus left'
            """,
        )
        assertEquals(errors, [])
        let binding = HotkeyBinding(.option, .h, [FocusCommand.new(direction: .left)])
        // User binding should override default
        assertEquals(
            config.modes[mainModeId]?.bindings[binding.descriptionWithKeyCode],
            binding,
        )
        // Should also contain default bindings (more than just the one user binding)
        XCTAssertTrue(config.modes[mainModeId]!.bindings.count > 1)
    }

    func testModesMustContainDefaultModeError() {
        let (config, errors) = parseConfig(
            """
            [mode.foo.binding]
                option-h = 'focus left'
            """,
        )
        assertEquals(errors, [])
        // 'main' mode comes from defaults
        XCTAssertNotNil(config.modes[mainModeId])
        // 'foo' mode is from user config
        XCTAssertNotNil(config.modes["foo"])
    }

    func testHotkeyParseError() {
        let (config, errors) = parseConfig(
            """
            [mode.main.binding]
                option-hh = 'focus left'
                aoption-j = 'focus down'
                option-k = 'focus up'
            """,
        )
        assertEquals(
            errors.descriptions,
            [
                "mode.main.binding.aoption-j: Can\'t parse modifiers in \'aoption-j\' binding",
                "mode.main.binding.option-hh: Can\'t parse the key in \'option-hh\' binding",
            ],
        )
        let binding = HotkeyBinding(.option, .k, [FocusCommand.new(direction: .up)])
        // User binding should be present
        assertEquals(
            config.modes[mainModeId]?.bindings[binding.descriptionWithKeyCode],
            binding,
        )
        // Should also have default bindings
        XCTAssertTrue(config.modes[mainModeId]!.bindings.count > 1)
    }

    func testPermanentWorkspaceNames() {
        let (config, errors) = parseConfig(
            """
            [mode.main.binding]
                option-1 = 'workspace 1'
                option-2 = 'workspace 2'
                option-3 = ['workspace 3']
                option-4 = ['workspace 4', 'focus left']
            """,
        )
        assertEquals(errors.descriptions, [])
        // User-defined workspaces should be present
        XCTAssertTrue(config.persistentWorkspaces.contains("1"))
        XCTAssertTrue(config.persistentWorkspaces.contains("2"))
        XCTAssertTrue(config.persistentWorkspaces.contains("3"))
        XCTAssertTrue(config.persistentWorkspaces.contains("4"))
    }

    func testUnknownTopLevelKeyParseError() {
        let (config, errors) = parseConfig(
            """
            unknownKey = true
            enable-normalization-flatten-containers = false
            """,
        )
        assertEquals(
            errors.descriptions,
            ["unknownKey: Unknown top-level key"],
        )
        assertEquals(config.enableNormalizationFlattenContainers, false)
    }

    func testUnknownKeyParseError() {
        let (config, errors) = parseConfig(
            """
            enable-normalization-flatten-containers = false
            [gaps]
                unknownKey = true
            """,
        )
        assertEquals(
            errors.descriptions,
            ["gaps.unknownKey: Unknown key"],
        )
        assertEquals(config.enableNormalizationFlattenContainers, false)
    }

    func testTypeMismatch() {
        let (_, errors) = parseConfig(
            """
            enable-normalization-flatten-containers = 'true'
            """,
        )
        assertEquals(
            errors.descriptions,
            ["enable-normalization-flatten-containers: Expected type is \'bool\'. But actual type is \'string\'"],
        )
    }

    func testTomlParseError() {
        let (_, errors) = parseConfig("true")
        assertEquals(
            errors.descriptions,
            ["Error while parsing key-value pair: encountered end-of-file (at line 1, column 5)"],
        )
    }

    func testMoveWorkspaceToMonitorCommandParsing() {
        XCTAssertTrue(parseCommand("move-workspace-to-monitor --wrap-around next").cmdOrNil is MoveWorkspaceToMonitorCommand)
        XCTAssertTrue(parseCommand("move-workspace-to-display --wrap-around next").cmdOrNil is MoveWorkspaceToMonitorCommand)
    }

    func testParseTiles() {
        let command = parseCommand("layout tiles h_tiles v_tiles list h_list v_list").cmdOrNil
        XCTAssertTrue(command is LayoutCommand)
        assertEquals((command as! LayoutCommand).args.toggleBetween.val, [.tiles, .h_tiles, .v_tiles, .tiles, .h_tiles, .v_tiles])

        guard case .help = parseCommand("layout tiles -h") else {
            XCTFail()
            return
        }
    }

    func testSplitCommandAndFlattenContainersNormalization() {
        let (_, errors) = parseConfig(
            """
            enable-normalization-flatten-containers = true
            [mode.main.binding]
            [mode.foo.binding]
                option-s = 'split horizontal'
            """,
        )
        assertEquals(
            errors.descriptions,
            ["""
                The config contains:
                1. usage of 'split' command
                2. enable-normalization-flatten-containers = true
                These two settings don't play nicely together. 'split' command has no effect when enable-normalization-flatten-containers is disabled.

                My recommendation: keep the normalizations enabled, and prefer 'join-with' over 'split'.
                """],
        )
    }

    func testParseWorkspaceToMonitorAssignment() {
        let (parsed, errors) = parseConfig(
            """
            [workspace-to-monitor-force-assignment]
                workspace_name_1 = 1                            # Sequence number of the monitor (from left to right, 1-based indexing)
                workspace_name_2 = 'main'                       # main monitor
                workspace_name_3 = 'secondary'                  # non-main monitor (in case when there are only two monitors)
                workspace_name_4 = 'built-in'                   # case insensitive regex substring
                workspace_name_5 = '^built-in retina display$'  # case insensitive regex match
                workspace_name_6 = ['secondary', 1]             # you can specify multiple patterns. The first matching pattern will be used
                7 = "foo"
                w7 = ['', 'main']
                w8 = 0
                workspace_name_x = '2'                          # Sequence number of the monitor (from left to right, 1-based indexing)
            """,
        )
        assertEquals(
            parsed.workspaceToMonitorForceAssignment,
            [
                "workspace_name_1": [.sequenceNumber(1)],
                "workspace_name_2": [.main],
                "workspace_name_3": [.secondary],
                "workspace_name_4": [.caseSensitivePattern("built-in")!],
                "workspace_name_5": [.caseSensitivePattern("^built-in retina display$")!],
                "workspace_name_6": [.secondary, .sequenceNumber(1)],
                "workspace_name_x": [.sequenceNumber(2)],
                "7": [.caseSensitivePattern("foo")!],
                "w7": [.main],
                "w8": [],
            ],
        )
        assertEquals([
            "workspace-to-monitor-force-assignment.w7[0]: Empty string is an illegal monitor description",
            "workspace-to-monitor-force-assignment.w8: Monitor sequence numbers uses 1-based indexing. Values less than 1 are illegal",
        ], errors.descriptions)
        assertEquals([:], defaultConfig.workspaceToMonitorForceAssignment)
    }

    func testParseOnWindowDetected() {
        let (parsed, errors) = parseConfig(
            """
            [[on-window-detected]] # 0
                check-further-callbacks = true
                run = ['layout floating', 'move-node-to-workspace W']
            [[on-window-detected]] # 1
                if.app-id = 'com.apple.systempreferences'
                run = []
            [[on-window-detected]] # 2
            [[on-window-detected]] # 3
                run = ['move-node-to-workspace S', 'layout tiling']
            [[on-window-detected]] # 4
                run = ['move-node-to-workspace S', 'move-node-to-workspace W']
            [[on-window-detected]] # 5
                run = ['move-node-to-workspace S', 'layout h_tiles']
            """,
        )
        assertEquals(parsed.onWindowDetected, [
            WindowDetectedCallback( // 0
                matcher: WindowDetectedCallbackMatcher(
                    appId: nil,
                    appNameRegexSubstring: nil,
                    windowTitleRegexSubstring: nil,
                ),
                checkFurtherCallbacks: true,
                rawRun: [
                    LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.floating])),
                    MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "W")),
                ],
            ),
            WindowDetectedCallback( // 1
                matcher: WindowDetectedCallbackMatcher(
                    appId: "com.apple.systempreferences",
                    appNameRegexSubstring: nil,
                    windowTitleRegexSubstring: nil,
                ),
                rawRun: [],
            ),
            WindowDetectedCallback( // 3
                rawRun: [
                    MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "S")),
                    LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.tiling])),
                ],
            ),
            WindowDetectedCallback( // 4
                rawRun: [
                    MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "S")),
                    MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "W")),
                ],
            ),
            WindowDetectedCallback( // 5
                rawRun: [
                    MoveNodeToWorkspaceCommand(args: MoveNodeToWorkspaceCmdArgs(workspace: "S")),
                    LayoutCommand(args: LayoutCmdArgs(rawArgs: [], toggleBetween: [.h_tiles])),
                ],
            ),
        ])

        assertEquals(errors.descriptions, [
            "on-window-detected[2]: \'run\' is mandatory key",
        ])
    }

    func testParseOnWindowDetectedRegex() {
        let (config, errors) = parseConfig(
            """
            [[on-window-detected]]
                if.app-name-regex-substring = '^system settings$'
                run = []
            """,
        )
        XCTAssertTrue(config.onWindowDetected.singleOrNil()!.matcher.appNameRegexSubstring != nil)
        assertEquals(errors, [])
    }

    func testRegex() {
        var devNull: [String] = []
        XCTAssertTrue("System Settings".contains(parseCaseInsensitiveRegex("settings").getOrNil(appendErrorTo: &devNull)!))
        XCTAssertTrue(!"System Settings".contains(parseCaseInsensitiveRegex("^settings^").getOrNil(appendErrorTo: &devNull)!))
    }

    func testParseGaps() {
        let (config, errors1) = parseConfig(
            """
            [gaps]
                inner.horizontal = 10
                inner.vertical = [{ monitor."main" = 1 }, { monitor."secondary" = 2 }, 5]
                outer.left = 12
                outer.bottom = 13
                outer.top = [{ monitor."built-in" = 3 }, { monitor."secondary" = 4 }, 6]
                outer.right = [{ monitor.2 = 7 }, 8]
            """,
        )
        assertEquals(errors1, [])
        assertEquals(
            config.gaps,
            Gaps(
                inner: .init(
                    vertical: .perMonitor(
                        [PerMonitorValue(description: .main, value: 1), PerMonitorValue(description: .secondary, value: 2)],
                        default: 5,
                    ),
                    horizontal: .constant(10),
                ),
                outer: .init(
                    left: .constant(12),
                    bottom: .constant(13),
                    top: .perMonitor(
                        [
                            PerMonitorValue(description: .caseSensitivePattern("built-in")!, value: 3),
                            PerMonitorValue(description: .secondary, value: 4),
                        ],
                        default: 6,
                    ),
                    right: .perMonitor([PerMonitorValue(description: .sequenceNumber(2), value: 7)], default: 8),
                ),
            ),
        )

        let (_, errors2) = parseConfig(
            """
            [gaps]
                inner.horizontal = [true]
                inner.vertical = [{ foo.main = 1 }, { monitor = { foo = 2, bar = 3 } }, 1]
            """,
        )
        assertEquals(errors2.descriptions, [
            "gaps.inner.horizontal: The last item in the array must be of type Int",
            "gaps.inner.vertical[0]: The table is expected to have a single key \'monitor\'",
            "gaps.inner.vertical[1].monitor: The table is expected to have a single key",
        ])
    }

    func testParseKeyMapping() {
        let (config, errors) = parseConfig(
            """
            [key-mapping.key-notation-to-key-code]
                q = 'q'
                unicorn = 'u'

            [mode.main.binding]
                option-unicorn = 'workspace wonderland'
            """,
        )
        assertEquals(errors.descriptions, [])
        assertEquals(config.keyMapping, KeyMapping(preset: .qwerty, rawKeyNotationToKeyCode: [
            "q": .q,
            "unicorn": .u,
        ]))
        let binding = HotkeyBinding(.option, .u, [WorkspaceCommand(args: WorkspaceCmdArgs(target: .direct(.parse("unicorn").getOrDie())))])
        assertEquals(config.modes[mainModeId]?.bindings[binding.descriptionWithKeyCode], binding)

        let (_, errors1) = parseConfig(
            """
            [key-mapping.key-notation-to-key-code]
                q = 'qw'
                ' f' = 'f'
            """,
        )
        assertEquals(errors1.descriptions, [
            "key-mapping.key-notation-to-key-code: ' f' is invalid key notation",
            "key-mapping.key-notation-to-key-code.q: 'qw' is invalid key code",
        ])

        let (dvorakConfig, dvorakErrors) = parseConfig(
            """
            key-mapping.preset = 'dvorak'
            """,
        )
        assertEquals(dvorakErrors, [])
        assertEquals(dvorakConfig.keyMapping, KeyMapping(preset: .dvorak, rawKeyNotationToKeyCode: [:]))
        assertEquals(dvorakConfig.keyMapping.resolve()["quote"], .q)
        let (colemakConfig, colemakErrors) = parseConfig(
            """
            key-mapping.preset = 'colemak'
            """,
        )
        assertEquals(colemakErrors, [])
        assertEquals(colemakConfig.keyMapping, KeyMapping(preset: .colemak, rawKeyNotationToKeyCode: [:]))
        assertEquals(colemakConfig.keyMapping.resolve()["f"], .e)
    }

    func testDisabledBindingRemovesDefault() {
        // Find a binding that exists in the default config
        let defaultBindings = defaultConfig.modes[mainModeId]!.bindings
        guard let (defaultKey, _) = defaultBindings.first else {
            XCTFail("Default config has no bindings")
            return
        }
        // Find the key notation for this binding from the default config
        let defaultBinding = defaultBindings[defaultKey]!

        let (config, errors) = parseConfig(
            """
            [mode.main.binding]
                \(defaultBinding.descriptionWithKeyNotation) = 'disabled'
            """,
        )
        assertEquals(errors, [])
        // The disabled binding should be removed
        XCTAssertNil(config.modes[mainModeId]?.bindings[defaultKey])
        // Other default bindings should still be present
        XCTAssertTrue(config.modes[mainModeId]!.bindings.count == defaultBindings.count - 1)
    }

    func testNoModeSectionInheritsDefaults() {
        let (config, errors) = parseConfig(
            """
            enable-normalization-flatten-containers = true
            """,
        )
        assertEquals(errors, [])
        assertEquals(config.modes[mainModeId]?.bindings, defaultConfig.modes[mainModeId]?.bindings)
    }

    func testDefaultOnlyModeIsPreserved() {
        // Default config has 'service' mode. User only defines 'main'.
        let (config, errors) = parseConfig(
            """
            [mode.main.binding]
                option-h = 'focus left'
            """,
        )
        assertEquals(errors, [])
        XCTAssertNotNil(config.modes["service"])
    }

    func testUserBindingOverridesDefault() {
        // option-h is 'focus left' in the default config. Override it with 'focus right'.
        let (config, errors) = parseConfig(
            """
            [mode.main.binding]
                option-h = 'focus right'
            """,
        )
        assertEquals(errors, [])
        let binding = HotkeyBinding(.option, .h, [FocusCommand.new(direction: .right)])
        assertEquals(
            config.modes[mainModeId]?.bindings[binding.descriptionWithKeyCode],
            binding,
        )
        // Verify this is NOT the default 'focus left' command
        let defaultBinding = HotkeyBinding(.option, .h, [FocusCommand.new(direction: .left)])
        assertNotEquals(
            config.modes[mainModeId]?.bindings[binding.descriptionWithKeyCode],
            defaultBinding,
        )
    }

    func testMultipleDisabledBindings() {
        let defaultBindings = defaultConfig.modes[mainModeId]!.bindings
        // Disable option-h, option-j, option-k (all 'focus' bindings)
        let (config, errors) = parseConfig(
            """
            [mode.main.binding]
                option-h = 'disabled'
                option-j = 'disabled'
                option-k = 'disabled'
            """,
        )
        assertEquals(errors, [])
        let hBinding = HotkeyBinding(.option, .h, [FocusCommand.new(direction: .left)])
        let jBinding = HotkeyBinding(.option, .j, [FocusCommand.new(direction: .down)])
        let kBinding = HotkeyBinding(.option, .k, [FocusCommand.new(direction: .up)])
        // All three should be removed
        XCTAssertNil(config.modes[mainModeId]?.bindings[hBinding.descriptionWithKeyCode])
        XCTAssertNil(config.modes[mainModeId]?.bindings[jBinding.descriptionWithKeyCode])
        XCTAssertNil(config.modes[mainModeId]?.bindings[kBinding.descriptionWithKeyCode])
        // Remaining count should be exactly 3 less than default
        assertEquals(config.modes[mainModeId]!.bindings.count, defaultBindings.count - 3)
    }

    func testUserModeOverridesDefaultMode() {
        // Default service mode has 'esc = ['reload-config', 'mode main']' (two commands).
        // Override it with a single command.
        let defaultServiceBindings = defaultConfig.modes["service"]!.bindings
        let escKeyCode = HotkeyBinding([], .escape, []).descriptionWithKeyCode
        let defaultEscBinding = defaultServiceBindings[escKeyCode]!
        // Default esc binding should have 2 commands
        assertEquals(defaultEscBinding.commands.count, 2)

        let (config, errors) = parseConfig(
            """
            [mode.service.binding]
                esc = 'mode main'
            """,
        )
        assertEquals(errors, [])
        // User override should have only 1 command
        let overriddenBinding = config.modes["service"]?.bindings[escKeyCode]
        assertNotNil(overriddenBinding)
        assertEquals(overriddenBinding!.commands.count, 1)
    }

    func testPartialUserModePreservesOtherDefaultBindings() {
        // User defines only one binding in main mode. All other defaults remain.
        let defaultBindings = defaultConfig.modes[mainModeId]!.bindings
        let (config, errors) = parseConfig(
            """
            [mode.main.binding]
                option-h = 'focus right'
            """,
        )
        assertEquals(errors, [])
        // Total binding count should be the same as defaults (one overridden, none removed)
        assertEquals(config.modes[mainModeId]!.bindings.count, defaultBindings.count)
        // Verify option-l default binding still exists (not overridden)
        let lBinding = HotkeyBinding(.option, .l, [FocusCommand.new(direction: .right)])
        assertEquals(
            config.modes[mainModeId]?.bindings[lBinding.descriptionWithKeyCode],
            lBinding,
        )
    }
}

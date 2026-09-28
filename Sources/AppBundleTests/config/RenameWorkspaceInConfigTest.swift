@testable import AppBundle
import XCTest

@MainActor
final class RenameWorkspaceInConfigTest: XCTestCase {
    func testRenamesPersistentWorkspacesAcrossLines() {
        let config = """
            persistent-workspaces = ["1", "2",
                                     "11", '1']
            gaps.outer.left = 1
            """
        assertEquals(renameWorkspaceInConfig(config, from: "1", to: "Web"), """
            persistent-workspaces = ["Web", "2",
                                     "11", 'Web']
            gaps.outer.left = 1
            """)
    }

    func testRenamesCommandArgumentsWithEitherQuoteAndFlags() {
        let config = """
            [mode.main.binding]
                option-1 = "workspace 1"
                option-2 = 'workspace --auto-back-and-forth 1'
                option-shift-1 = ['move-node-to-workspace --window-id 1 1', 'workspace 1']
                option-3 = 'summon-workspace 1 && layout floating; workspace 11'
                option-4 = 'balance-sizes --workspace 1'
                option-5 = 'list-windows --workspace 2,1,11'
                option-6 = 'focus --window-id 1'
                option-7 = 'workspace next' # workspace 1
            """
        assertEquals(renameWorkspaceInConfig(config, from: "1", to: "Web"), """
            [mode.main.binding]
                option-1 = "workspace Web"
                option-2 = 'workspace --auto-back-and-forth Web'
                option-shift-1 = ['move-node-to-workspace --window-id 1 Web', 'workspace Web']
                option-3 = 'summon-workspace Web && layout floating; workspace 11'
                option-4 = 'balance-sizes --workspace Web'
                option-5 = 'list-windows --workspace 2,Web,11'
                option-6 = 'focus --window-id 1'
                option-7 = 'workspace next' # workspace 1
            """)
    }

    func testRenamesTableKeysButNotTheirValues() {
        let config = """
            [workspace-to-monitor-force-assignment]
                1 = '1'
                "2" = 'built-in'

            [workspaces.names]
                1 = "1"
            """
        assertEquals(renameWorkspaceInConfig(config, from: "1", to: "Web"), """
            [workspace-to-monitor-force-assignment]
                Web = '1'
                "2" = 'built-in'

            [workspaces.names]
                Web = "1"
            """)
        assertEquals(renameWorkspaceInConfig(config, from: "2", to: "Mail"), """
            [workspace-to-monitor-force-assignment]
                1 = '1'
                "Mail" = 'built-in'

            [workspaces.names]
                1 = "1"
            """)
        assertEquals(
            renameWorkspaceInConfig("[workspaces.names]\n    1 = \"1\"", from: "1", to: "A.B"),
            "[workspaces.names]\n    \"A.B\" = \"1\"",
        )
    }

    func testLeavesMultiLineStringsAlone() {
        let config = """
            [mode.main.binding]
                option-1 = '''
                workspace 1
                '''
                option-2 = 'workspace 1'
            """
        assertEquals(renameWorkspaceInConfig(config, from: "1", to: "Web"), """
            [mode.main.binding]
                option-1 = '''
                workspace 1
                '''
                option-2 = 'workspace Web'
            """)
    }

    func testRenamedWorkspacesShorthandStillParses() {
        let config = """
            config-version = 2
            [workspaces.names]
                1 = "1"
                2 = "2"
            """
        let renamed = renameWorkspaceInConfig(config, from: "1", to: "Web")
        let (parsed, errors) = parseConfig(renamed)
        assertEquals(errors.map(\.description), [])
        assertTrue(parsed.persistentWorkspaces.contains("Web"))
        assertTrue(!parsed.persistentWorkspaces.contains("1"))
    }

    func testRenamesWindowDetectedMatcherAndRun() {
        let config = """
            [[on-window-detected]]
                if.workspace = '1'
                run = ['move-node-to-workspace 1', 'layout floating']

            [[on-window-detected]]
                if.window-title-regex-substring = 'workspace 1'
                run = 'layout floating'
            """
        assertEquals(renameWorkspaceInConfig(config, from: "1", to: "Web"), """
            [[on-window-detected]]
                if.workspace = 'Web'
                run = ['move-node-to-workspace Web', 'layout floating']

            [[on-window-detected]]
                if.window-title-regex-substring = 'workspace 1'
                run = 'layout floating'
            """)
    }

    func testLeavesStringsOutsideCommandFieldsAlone() {
        let config = """
            after-startup-command = ['workspace 1']
            [exec.env-vars]
                RULE = 'workspace 1'
            [mode.main.binding]
                option-1 = 'workspace 1'
            """
        assertEquals(renameWorkspaceInConfig(config, from: "1", to: "Web"), """
            after-startup-command = ['workspace Web']
            [exec.env-vars]
                RULE = 'workspace 1'
            [mode.main.binding]
                option-1 = 'workspace Web'
            """)
    }

    func testReportsReferencesTheRewriteCannotReach() {
        let config = """
            config-version = 2
            [workspaces]
                names = { 1 = "1" }
            """
        let renamed = renameWorkspaceInConfig(config, from: "1", to: "Web")
        let (parsed, errors) = parseConfig(renamed)
        assertEquals(errors.map(\.description), [])
        assertTrue(configStillReferences(parsed, workspace: "1"))
    }

    func testReportsCommandsTheRewriteCannotReach() {
        let config = """
            config-version = 2
            persistent-workspaces = ["1"]
            [mode.main.binding]
                option-1 = \"\"\"workspace 1\"\"\"
                option-2 = 'workspace 2'
            """
        let renamed = renameWorkspaceInConfig(config, from: "1", to: "Web")
        assertEquals(parseConfig(renamed).errors.map(\.description), [])
        let parsed = parseConfig(renamed, mergeWithDefaults: false).config
        assertTrue(configStillReferences(parsed, workspace: "1"))
        assertTrue(!configStillReferences(parsed, workspace: "3"))
    }

    func testWriteConfigFileKeepsSymlink() throws {
        let dir = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(component: "airlock.toml")
        let link = dir.appending(component: ".airlock.toml")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        try writeConfigFile("new", to: link)

        assertEquals(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), target.path)
        assertEquals(try String(contentsOf: target, encoding: .utf8), "new")
    }
}

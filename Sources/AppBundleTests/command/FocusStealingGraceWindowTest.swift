@testable import AppBundle
import Common
import XCTest

@MainActor
final class FocusStealingGraceWindowTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    /// A status bar polling `list-workspaces` once a second must not keep the
    /// user-initiated grace window permanently open, which would disable
    /// `prevent-focus-stealing` entirely.
    func testQueryCommandsDontOpenTheGraceWindow() {
        let queries = [
            "list-workspaces --all",
            "list-windows --all",
            "list-monitors",
            "list-apps",
            "list-modes",
            "list-exec-env-vars",
            "debug-windows",
        ]
        for query in queries {
            switch parseCommand(query) {
                case .cmd(let command):
                    XCTAssertFalse(command.info.kind.mayChangeFocus, "'\(query)' should not open the grace window")
                case .failure(let msg): XCTFail("'\(query)': \(msg)")
                case .help: XCTFail("'\(query)': unexpected help")
            }
        }
    }

    func testFocusChangingCommandsOpenTheGraceWindow() {
        let commands = [
            "focus left",
            "workspace 1",
            "summon-workspace 1",
            "move-node-to-workspace 1",
            "mode main",
            "focus-monitor left",
        ]
        for cmd in commands {
            switch parseCommand(cmd) {
                case .cmd(let command):
                    XCTAssertTrue(command.info.kind.mayChangeFocus, "'\(cmd)' should open the grace window")
                case .failure(let msg): XCTFail("'\(cmd)': \(msg)")
                case .help: XCTFail("'\(cmd)': unexpected help")
            }
        }
    }
}

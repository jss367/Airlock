@testable import AppBundle
import Common
import XCTest

@MainActor
final class ExecCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testExecRequiresACompleteCommandName() {
        assertEquals(parseCommand("exec-and-forgetful echo foo").errorOrNil, "Unrecognized subcommand 'exec-and-forgetful'")
    }

    func testExecPreservesScriptAfterLeadingWhitespace() {
        testParseCommandSucc("  exec-and-forget\techo 'foo'", ExecAndForgetCmdArgs(bashScript: "\techo 'foo'"))
    }

    func testParseExecCommand() {
        testParseCommandSucc("exec-and-forget echo 'foo'", ExecAndForgetCmdArgs(bashScript: " echo 'foo'"))
    }
}

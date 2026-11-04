@testable import AppBundle
import Common
import XCTest

@MainActor
final class TriggerBindingCommandTest: XCTestCase {
    override func setUp() async throws {
        setUpWorkspacesForTests()
        RecursionTailFixtureCommand.calls = 0
    }

    func testBindingThatTriggersItselfFailsInsteadOfHanging() async throws {
        let binding = HotkeyBinding(.option, .a, [parseCommand("trigger-binding alt-a --mode main").cmdOrDie], descriptionWithKeyNotation: "alt-a")
        config.modes[mainModeId] = Mode(bindings: [binding.descriptionWithKeyCode: binding])

        let result = try await parseCommand("trigger-binding alt-a --mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode, 1)
        assertEquals(result.stderr.count, 1)
        assertTrue(result.stderr.first?.contains("nested more than \(TriggerBindingCommand.maxDepth) levels deep") == true)
    }

    func testBindingsThatTriggerEachOtherFailInsteadOfHanging() async throws {
        let a = HotkeyBinding(.option, .a, [parseCommand("trigger-binding alt-b --mode main").cmdOrDie], descriptionWithKeyNotation: "alt-a")
        let b = HotkeyBinding(.option, .b, [parseCommand("trigger-binding alt-a --mode main").cmdOrDie], descriptionWithKeyNotation: "alt-b")
        config.modes[mainModeId] = Mode(bindings: [a.descriptionWithKeyCode: a, b.descriptionWithKeyCode: b])

        let result = try await parseCommand("trigger-binding alt-a --mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode, 1)
        assertEquals(TriggerBindingCommand.depth, 0)
    }

    func testNestedTriggerWithinTheLimitRuns() async throws {
        let inner = HotkeyBinding(.option, .b, [parseCommand("workspace B").cmdOrDie], descriptionWithKeyNotation: "alt-b")
        let outer = HotkeyBinding(.option, .a, [parseCommand("trigger-binding alt-b --mode main").cmdOrDie], descriptionWithKeyNotation: "alt-a")
        config.modes[mainModeId] = Mode(bindings: [inner.descriptionWithKeyCode: inner, outer.descriptionWithKeyCode: outer])

        let result = try await parseCommand("trigger-binding alt-a --mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode, 0)
        assertEquals(focus.workspace.name, "B")
    }
    func testBranchingSelfCycleAbortsWithBoundedWork() async throws {
        try await exerciseBoundedBranchingCycle(mutual: false)
    }

    func testBranchingMutualCycleAbortsWithBoundedWork() async throws {
        try await exerciseBoundedBranchingCycle(mutual: true)
    }

    private func exerciseBoundedBranchingCycle(mutual: Bool) async throws {
        let target = mutual ? "alt-b" : "alt-a"
        let a = HotkeyBinding(.option, .a, [parseCommand("trigger-binding \(target) --mode main").cmdOrDie,
                                            parseCommand("trigger-binding \(target) --mode main").cmdOrDie, RecursionTailFixtureCommand()], descriptionWithKeyNotation: "alt-a")
        let b = HotkeyBinding(.option, .b, [parseCommand("trigger-binding alt-a --mode main").cmdOrDie,
                                            parseCommand("trigger-binding alt-a --mode main").cmdOrDie, RecursionTailFixtureCommand()], descriptionWithKeyNotation: "alt-b")
        config.modes[mainModeId] = Mode(bindings: [a.descriptionWithKeyCode: a, b.descriptionWithKeyCode: b])
        var terminalError = false
        // Leave only four levels: the unfixed branching tree is at most 16 leaves, never depth 32.
        do {
            let result = try await TriggerBindingCommand.$depth.withValue(TriggerBindingCommand.maxDepth - 4) {
                try await parseCommand("trigger-binding alt-a --mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)
            }
            XCTAssertLessThanOrEqual(result.stderr.count, 1, "One cycle must not fan out into many failures")
        } catch { terminalError = true }
        XCTAssertTrue(terminalError, "A nested depth failure must unwind all nested command sequences")
        assertEquals(RecursionTailFixtureCommand.calls, 0)
        assertEquals(TriggerBindingCommand.depth, 0)
    }

    func testAcyclicSiblingTriggersCanReuseBinding() async throws {
        let b = HotkeyBinding(.option, .b, [RecursionTailFixtureCommand()], descriptionWithKeyNotation: "alt-b")
        let a = HotkeyBinding(.option, .a, [parseCommand("trigger-binding alt-b --mode main").cmdOrDie,
                                            parseCommand("trigger-binding alt-b --mode main").cmdOrDie], descriptionWithKeyNotation: "alt-a")
        config.modes[mainModeId] = Mode(bindings: [a.descriptionWithKeyCode: a, b.descriptionWithKeyCode: b])
        let result = try await parseCommand("trigger-binding alt-a --mode main").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 0)
        assertEquals(RecursionTailFixtureCommand.calls, 2)
    }

    func testOrdinaryCommandFailureStillRunsNextCommand() async throws {
        let commands: [any Command] = [parseCommand("trigger-binding alt-a --mode missing").cmdOrDie, RecursionTailFixtureCommand()]
        let result = try await commands.runCmdSeq(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode, 1)
        assertEquals(RecursionTailFixtureCommand.calls, 1)
    }
}


private struct RecursionTailFixtureCommand: Command {
    @MainActor static var calls = 0
    let args = EnableCmdArgs(rawArgs: [], targetState: .on)
    let shouldResetClosedWindowsCache = false
    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool { Self.calls += 1; return true }
}

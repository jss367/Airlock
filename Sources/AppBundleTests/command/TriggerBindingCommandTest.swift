@testable import AppBundle
import Common
import XCTest

@MainActor
final class TriggerBindingCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

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
}

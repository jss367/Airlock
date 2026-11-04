import AppKit
import Common

struct TriggerBindingCommand: Command {
    let args: TriggerBindingCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    /// How many `trigger-binding` commands are running inside each other. A binding that triggers itself,
    /// directly or through other bindings, would otherwise recurse forever and hang the main thread
    @TaskLocal static var depth = 0
    static let maxDepth = 32

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        guard let mode = config.modes[args.mode] else {
            return io.err("Mode '\(args.mode)' doesn't exist. " +
                "Available modes: \(config.modes.keys.joined(separator: ","))")
        }
        guard let binding = mode.bindings.values.first(where: { $0.descriptionWithKeyNotation == args.binding.val }) else {
            return io.err("Binding '\(args.binding.val)' is not presented in mode '\(args.mode)'")
        }
        guard Self.depth < Self.maxDepth else {
            throw TriggerBindingRecursionError(message:
                "Binding '\(args.binding.val)' in mode '\(args.mode)' wasn't run: 'trigger-binding' is nested " +
                    "more than \(Self.maxDepth) levels deep. Does a binding trigger itself?")
        }
        do {
            // refreshSession is not needed since commands are already run in refreshSession
            return try await Self.$depth.withValue(Self.depth + 1) {
                try await binding.commands.runCmdSeq(env, io)
            }
        } catch let error as TriggerBindingRecursionError {
            // Abort every nested binding sequence, including its remaining commands.
            // Report one failure at the outermost trigger; unrelated outer commands keep their
            // normal sequence behavior after a failed command.
            guard Self.depth == 0 else { throw error }
            return io.err(error.message)
        }
    }
}

private struct TriggerBindingRecursionError: Error {
    let message: String
}

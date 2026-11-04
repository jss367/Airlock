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
        return if let mode = config.modes[args.mode] {
            if let binding = mode.bindings.values.first(where: { $0.descriptionWithKeyNotation == args.binding.val }) {
                if Self.depth >= Self.maxDepth {
                    io.err("Binding '\(args.binding.val)' in mode '\(args.mode)' wasn't run: 'trigger-binding' is nested " +
                        "more than \(Self.maxDepth) levels deep. Does a binding trigger itself?")
                } else {
                    // refreshSession is not needed since commands are already run in refreshSession
                    try await Self.$depth.withValue(Self.depth + 1) {
                        try await binding.commands.runCmdSeq(env, io)
                    }
                }
            } else {
                io.err("Binding '\(args.binding.val)' is not presented in mode '\(args.mode)'")
            }
        } else {
            io.err("Mode '\(args.mode)' doesn't exist. " +
                "Available modes: \(config.modes.keys.joined(separator: ","))")
        }
    }
}

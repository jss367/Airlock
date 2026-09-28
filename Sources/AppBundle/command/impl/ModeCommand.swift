import AppKit
import Common

struct ModeCommand: Command {
    let args: ModeCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        let targetMode = args.targetMode.val
        // Activating a mode that doesn't exist would disable every hotkey
        guard config.modes[targetMode] != nil else {
            return io.err("Mode '\(targetMode)' doesn't exist. Available modes: \(config.modes.keys.sorted().joined(separator: ","))")
        }
        try await activateMode(targetMode)
        return true
    }
}

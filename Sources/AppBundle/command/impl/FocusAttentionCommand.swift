import AppKit
import Common

struct FocusAttentionCommand: Command {
    let args: FocusAttentionCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        guard let request = focusAttention.pending.first, let window = Window.get(byId: request.windowId) else {
            return io.err("No window is waiting for focus")
        }
        // Arriving on the workspace ends every request there. Ending this one by hand keeps it from
        // coming back first if the focus can't be applied
        focusAttention.clear(windowId: request.windowId)
        return window.focusWindow()
    }
}

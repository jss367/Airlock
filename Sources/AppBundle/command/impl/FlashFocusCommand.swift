import AppKit
import Common

struct FlashFocusCommand: Command {
    let args: FlashFocusCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) -> Bool {
        // No-op stub. Wired to FocusFlashController in Task 7 once the
        // controller (Task 5) and overlay (Task 4) exist.
        return true
    }
}

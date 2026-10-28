import AppKit
import Common

struct FullscreenCommand: Command {
    let args: FullscreenCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else {
            return io.err(noWindowIsFocused)
        }
        let newState: Bool = switch args.toggle {
            case .on: true
            case .off: false
            case .toggle: !window.isFullscreen
        }
        if newState == window.isFullscreen {
            io.err((newState ? "Already fullscreen. " : "Already not fullscreen. ") +
                "Tip: use --fail-if-noop to exit with non-zero code")
            return !args.failIfNoop
        }
        if window.isFloating || !config.enableWindowManagement {
            guard let rect = try await window.getAxRect() else { return io.err("Cannot read the window frame") }
            guard window.isBound else { return io.err("Window \(window.windowId) was closed while maximizing it") }
            let monitor = config.enableWindowManagement ? target.workspace.workspaceMonitor : rect.center.monitorApproximation
            if newState {
                window.floatingFullscreenRestore = FloatingFullscreenRestore(frame: rect, monitorVisibleRect: monitor.visibleRect)
                let frame = args.noOuterGaps ? monitor.visibleRect : monitor.visibleRectPaddedByOuterGaps
                window.setAxFrame(frame.topLeftCorner, frame.size)
            } else if let restore = window.floatingFullscreenRestore {
                let point = restore.monitorVisibleRect == monitor.visibleRect
                    ? restore.frame.topLeftCorner
                    : windowPositionOnMonitor(restore.frame, from: restore.monitorVisibleRect, to: monitor.visibleRect)
                window.setAxFrame(point, restore.frame.size)
                window.lastFloatingSize = restore.frame.size
                window.floatingFullscreenRestore = nil
            }
        }
        window.isFullscreen = newState
        window.noOuterGapsInFullscreen = args.noOuterGaps

        // Focus on its own workspace
        window.markAsMostRecentChild()
        return true
    }
}

let noWindowIsFocused = "No window is focused"

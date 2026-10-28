import AppKit
import Common

struct WindowFrameCommand: Command {
    let args: WindowFrameCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else { return io.err(noWindowIsFocused) }
        guard window.parent is Workspace || window.parent is TilingContainer else {
            return io.err("Can't position macOS fullscreen, minimized, or hidden windows")
        }
        guard let rect = try await window.getAxRect() else { return io.err("Cannot read the window frame") }
        guard window.isBound else { return io.err("Window \(window.windowId) was closed while positioning it") }
        let monitor = config.enableWindowManagement
            ? target.workspace.workspaceMonitor
            : rect.center.monitorApproximation
        let frame = windowFrame(args.preset.val, current: rect, visible: monitor.visibleRect)
        // Explicit placement takes this window out of automatic tiling.
        window.bindAsFloatingWindow(to: target.workspace)
        window.clearFullscreen()
        window.lastFloatingSize = frame.size
        window.setAxFrame(frame.topLeftCorner, frame.size)
        return true
    }
}

func windowFrame(_ preset: WindowFrameCmdArgs.Preset, current: Rect, visible: Rect) -> Rect {
    switch preset {
        case .leftHalf:
            return Rect(topLeftX: visible.minX, topLeftY: visible.minY, width: visible.width / 2, height: visible.height)
        case .rightHalf:
            return Rect(topLeftX: visible.center.x, topLeftY: visible.minY, width: visible.width / 2, height: visible.height)
        case .center, .comfortable:
            let size = preset == .center ? current.size : CGSize(width: visible.width * 0.75, height: visible.height * 0.75)
            return Rect(
                topLeftX: visible.center.x - size.width / 2,
                topLeftY: visible.center.y - size.height / 2,
                width: size.width,
                height: size.height,
            )
    }
}

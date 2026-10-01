import AppKit
import Common

struct MoveNodeToMonitorCommand: Command {
    let args: MoveNodeToMonitorCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        guard let window = target.windowOrNil else {
            return io.err(noWindowIsFocused)
        }
        let nativeRect = !config.enableWindowManagement ? try await window.getAxRect() : nil
        guard let currentMonitor = nativeRect?.center.monitorApproximation ?? window.nodeMonitor else {
            return io.err(windowIsntPartOfTree(window))
        }
        switch args.target.val.resolve(currentMonitor, wrapAround: args.wrapAround) {
            case .success(let targetMonitor):
                if !config.enableWindowManagement {
                    guard let nativeRect else { return io.err("Cannot read the window frame") }
                    if currentMonitor.rect.topLeftCorner == targetMonitor.rect.topLeftCorner {
                        return !args.failIfNoop
                    }
                    let point = windowPositionOnMonitor(nativeRect, from: currentMonitor.visibleRect, to: targetMonitor.visibleRect)
                    let wasFocused = focus.windowOrNil == window
                    if let macWindow = window as? MacWindow {
                        try await macWindow.setAxFrameBlocking(point, nil)
                    } else {
                        window.setAxFrame(point, nil)
                    }
                    let workspace = targetMonitor.activeWorkspace
                    let container: NonLeafTreeNodeObject = window.isFloating ? workspace : workspace.rootTilingContainer
                    window.bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
                    return wasFocused || args.focusFollowsWindow ? window.focusWindow() : true
                }
                let targetWs = targetMonitor.activeWorkspace
                let index = true == args.target.val.directionOrNil
                    .map { dir in dir.isPositive && targetWs.rootTilingContainer.orientation == dir.orientation }
                    ? 0
                    : INDEX_BIND_LAST
                return moveWindowToWorkspace(
                    window,
                    targetWs,
                    io,
                    focusFollowsWindow: args.focusFollowsWindow,
                    failIfNoop: args.failIfNoop,
                    index: index,
                )
            case .failure(let msg):
                return io.err(msg)
        }
    }
}

func windowIsntPartOfTree(_ window: Window) -> String {
    "Window \(window.windowId) is not part of tree (minimized or hidden)"
}

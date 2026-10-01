import AppKit
import Common

/// Track the window's native monitor without changing its frame. Keeping the model in sync
/// makes shortcuts work after a window is dragged across displays while management is off.
@MainActor
func syncUnmanagedWindow(_ window: Window) async throws {
    guard window.layoutReason == .standard,
          let parent = window.parent,
          parent is Workspace || parent is TilingContainer,
          let rect = try await window.getAxRect()
    else { return }
    let workspace = rect.center.monitorApproximation.activeWorkspace
    if window.nodeWorkspace != workspace {
        resetClosedWindowsCache()
        let wasFocused = focus.windowOrNil == window
        let container: NonLeafTreeNodeObject = window.isFloating ? workspace : workspace.rootTilingContainer
        window.bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: INDEX_BIND_LAST)
        if wasFocused { _ = window.focusWindow() }
    }
}

/// Preserve size and relative position, clamping the top left so smaller monitors remain usable.
func windowPositionOnMonitor(_ window: Rect, from source: Rect, to destination: Rect) -> CGPoint {
    let x = destination.minX + (window.minX - source.minX) / source.width * destination.width
    let y = destination.minY + (window.minY - source.minY) / source.height * destination.height
    return CGPoint(
        x: x.coerce(in: destination.minX ... max(destination.minX, destination.maxX - window.width)),
        y: y.coerce(in: destination.minY ... max(destination.minY, destination.maxY - window.height)),
    )
}

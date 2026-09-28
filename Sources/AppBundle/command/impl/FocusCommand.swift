import AppKit
import Common

struct FocusCommand: Command {
    let args: FocusCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = false

    func run(_ env: CmdEnv, _ io: CmdIo) async throws -> Bool {
        guard let target = args.resolveTargetOrReportError(env, io) else { return false }
        let floatingSnapshot: FloatingWindowsSnapshot? = args.floatingAsTiling ? try await makeFloatingWindowsSeenAsTiling(workspace: target.workspace) : nil
        defer {
            if let floatingSnapshot {
                restoreFloatingWindows(floatingSnapshot, workspace: target.workspace)
            }
        }

        switch args.target {
            case .direction(let direction):
                let window = target.windowOrNil
                if let (parent, ownIndex) = window?.closestParent(hasChildrenInDirection: direction, withLayout: nil) {
                    guard let windowToFocus = parent.children[ownIndex + direction.focusOffset]
                        .findLeafWindowRecursive(snappedTo: direction.opposite) else { return false }
                    return windowToFocus.focusWindow()
                } else {
                    return hitWorkspaceBoundaries(target, io, args, direction)
                }
            case .windowId(let windowId):
                if let windowToFocus = Window.get(byId: windowId) {
                    return windowToFocus.focusWindow()
                } else {
                    return io.err("Can't find window with ID \(windowId)")
                }
            case .dfsIndex(let dfsIndex):
                if let windowToFocus = target.workspace.rootTilingContainer.allLeafWindowsRecursive.getOrNil(atIndex: Int(dfsIndex)) {
                    return windowToFocus.focusWindow()
                } else {
                    return io.err("Can't find window with DFS index \(dfsIndex)")
                }
            case .dfsRelative(let nextPrev):
                let windows = target.workspace.rootTilingContainer.allLeafWindowsRecursive
                guard let currentIndex = windows.firstIndex(where: { $0 == target.windowOrNil }) else {
                    return false
                }
                var targetIndex = switch nextPrev {
                    case .dfsNext: currentIndex + 1
                    case .dfsPrev: currentIndex - 1
                }
                if !(0 ..< windows.count).contains(targetIndex) {
                    switch args.boundariesAction {
                        case .stop: return true
                        case .fail: return false
                        case .wrapAroundTheWorkspace: targetIndex = (targetIndex + windows.count) % windows.count
                        case .wrapAroundAllMonitors: return dieT("Must be discarded by args parser")
                    }
                }
                return windows[targetIndex].focusWindow()
            case .appCycle(let appDir):
                return cycleAppFocus(target: target, direction: appDir)
        }
    }
}

/// Cycle focus between apps or between windows of the same app, within the current workspace.
@MainActor private func cycleAppFocus(target: LiveFocus, direction: AppCycleDirection) -> Bool {
    let allWindows = target.workspace.allLeafWindowsRecursive
    guard let currentWindow = target.windowOrNil else { return false }
    let currentPid = currentWindow.app.pid

    switch direction {
        case .appNext, .appPrev:
            if isAppSwitcherVisible {
                cycleAppSwitcher(direction: direction)
            } else {
                showAppSwitcher(direction: direction)
            }
            return true

        case .sameAppNext, .sameAppPrev:
            let sameAppWindows = allWindows.filter { $0.app.pid == currentPid }
            guard sameAppWindows.count > 1 else { return true } // only one window, nothing to cycle
            guard let currentIndex = sameAppWindows.firstIndex(where: { $0.windowId == currentWindow.windowId }) else { return false }

            let offset = direction == .sameAppNext ? 1 : -1
            let nextIndex = (currentIndex + offset + sameAppWindows.count) % sameAppWindows.count
            return sameAppWindows[nextIndex].focusWindow()
    }
}

@MainActor private func hitWorkspaceBoundaries(
    _ target: LiveFocus,
    _ io: CmdIo,
    _ args: FocusCmdArgs,
    _ direction: CardinalDirection,
) -> Bool {
    switch args.boundaries {
        case .workspace:
            return switch args.boundariesAction {
                case .stop: true
                case .fail: false
                case .wrapAroundTheWorkspace: wrapAroundTheWorkspace(target, io, direction)
                case .wrapAroundAllMonitors: dieT("Must be discarded by args parser")
            }
        case .allMonitorsOuterFrame:
            let currentMonitor = target.workspace.workspaceMonitor
            guard let (monitors, index) = currentMonitor.findRelativeMonitor(inDirection: direction) else {
                return io.err("Should never happen. Can't find the current monitor")
            }

            if let targetMonitor = monitors.getOrNil(atIndex: index) {
                return targetMonitor.activeWorkspace.focusWorkspace()
            } else {
                guard let wrapped = monitors.get(wrappingIndex: index) else { return false }
                return hitAllMonitorsOuterFrameBoundaries(target, io, args, direction, wrapped)
            }
    }
}

@MainActor private func hitAllMonitorsOuterFrameBoundaries(
    _ target: LiveFocus,
    _ io: CmdIo,
    _ args: FocusCmdArgs,
    _ direction: CardinalDirection,
    _ wrappedMonitor: Monitor,
) -> Bool {
    switch args.boundariesAction {
        case .stop:
            return true
        case .fail:
            return false
        case .wrapAroundTheWorkspace:
            return wrapAroundTheWorkspace(target, io, direction)
        case .wrapAroundAllMonitors:
            wrappedMonitor.activeWorkspace.findLeafWindowRecursive(snappedTo: direction.opposite)?.markAsMostRecentChild()
            return wrappedMonitor.activeWorkspace.focusWorkspace()
    }
}

@MainActor private func wrapAroundTheWorkspace(_ target: LiveFocus, _ io: CmdIo, _ direction: CardinalDirection) -> Bool {
    guard let windowToFocus = target.workspace.findLeafWindowRecursive(snappedTo: direction.opposite) else {
        return io.err(noWindowIsFocused)
    }
    return windowToFocus.focusWindow()
}

@MainActor private func makeFloatingWindowsSeenAsTiling(workspace: Workspace) async throws -> FloatingWindowsSnapshot {
    let workspaceMruSnapshot = workspace.mruSnapshot()
    let focusedWindow = focus.windowOrNil
    // Every AX query happens before any window is unbound. A refresh can run during a query, and one
    // that garbage-collects a window already unbound here would crash on unbinding it again
    var candidates: [(window: Window, center: CGPoint, parent: TilingContainer, index: Int)] = []
    for window in workspace.floatingWindows {
        let center = try await window.getCenter()
        guard let center else { continue }

        if let target = center.coerce(in: workspace.workspaceMonitor.visibleRectPaddedByOuterGaps)?
            .findIn(tree: workspace.rootTilingContainer, virtual: true)
        {
            guard let targetCenter = try await target.getCenter() else { continue }
            guard let tilingParent = target.parent as? TilingContainer, let targetIndex = target.ownIndex else { continue }
            let index = center.getProjection(tilingParent.orientation) >= targetCenter.getProjection(tilingParent.orientation)
                ? targetIndex + 1
                : targetIndex
            candidates.append((window, center, tilingParent, index))
        } else {
            candidates.append((window, center, workspace.rootTilingContainer, 0))
        }
    }

    var floatingWindows: [FloatingWindowData] = []
    for candidate in candidates {
        // The queries above suspend, which lets other main actor work mutate the tree. The window
        // may have been closed or moved to another parent by now, and so may its tiling target
        guard candidate.window.parent === workspace else { continue }
        let isParentAttached = candidate.parent.nodeWorkspace === workspace
        let parent = isParentAttached ? candidate.parent : workspace.rootTilingContainer
        let data = candidate.window.unbindFromParent()
        floatingWindows.append(FloatingWindowData(
            window: candidate.window,
            center: candidate.center,
            parent: parent,
            adaptiveWeight: data.adaptiveWeight,
            index: isParentAttached ? min(candidate.index, parent.children.count) : 0,
        ))
    }

    let bindOrder: [FloatingWindowData] = floatingWindows.sortedBy { $0.center.getProjection($0.parent.orientation) }.reversed()
    for floating in bindOrder { // Make floating windows be seen as tiling
        floating.window.bind(to: floating.parent, adaptiveWeight: 1, index: floating.index, updateMru: false)
    }
    // Keep the workspace order, so restoring doesn't reorder floating windows on every focus call
    return FloatingWindowsSnapshot(windows: floatingWindows, workspaceMruSnapshot: workspaceMruSnapshot, focusedWindow: focusedWindow)
}

@MainActor private func restoreFloatingWindows(_ snapshot: FloatingWindowsSnapshot, workspace: Workspace) {
    for floating in snapshot.windows {
        floating.window.bind(to: workspace, adaptiveWeight: floating.adaptiveWeight, index: INDEX_BIND_LAST, updateMru: false)
    }
    // Restore workspace MRU to the exact order before the floating-as-tiling operation,
    // so that floating windows retain their prior recency positions.
    workspace.restoreMruOrder(from: snapshot.workspaceMruSnapshot)
    // The snapshot predates the focus change, so the replay just demoted the newly focused window.
    // Only re-raise it if focus actually changed, otherwise keep the snapshot's order as is
    if let window = focus.windowOrNil, window !== snapshot.focusedWindow, window.nodeWorkspace == workspace {
        window.markAsMostRecentChild()
    }
}

private struct FloatingWindowsSnapshot {
    let windows: [FloatingWindowData]
    let workspaceMruSnapshot: [TreeNode]
    let focusedWindow: Window?
}

private struct FloatingWindowData {
    let window: Window
    let center: CGPoint

    let parent: TilingContainer
    let adaptiveWeight: CGFloat
    let index: Int
}

extension TreeNode {
    @MainActor
    func findLeafWindowRecursive(snappedTo direction: CardinalDirection) -> Window? {
        switch nodeCases {
            case .workspace(let workspace):
                return workspace.rootTilingContainer.findLeafWindowRecursive(snappedTo: direction)
            case .window(let window):
                return window
            case .tilingContainer(let container):
                if direction.orientation == container.orientation {
                    return (direction.isPositive ? container.children.last : container.children.first)?
                        .findLeafWindowRecursive(snappedTo: direction)
                } else {
                    return mostRecentChild?.findLeafWindowRecursive(snappedTo: direction)
                }
            case .macosMinimizedWindowsContainer, .macosFullscreenWindowsContainer,
                 .macosPopupWindowsContainer, .macosHiddenAppsWindowsContainer:
                die("Impossible")
        }
    }
}

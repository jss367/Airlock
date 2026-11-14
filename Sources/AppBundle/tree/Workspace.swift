import AppKit
import Common

@MainActor private var workspaceNameToWorkspace: [String: Workspace] = [:]

@MainActor private var screenPointToPrevVisibleWorkspace: [CGPoint: String] = [:]
@MainActor private var screenPointToVisibleWorkspace: [CGPoint: Workspace] = [:]
@MainActor private var visibleWorkspaceToScreenPoint: [Workspace: CGPoint] = [:]

// The returned workspace must be invisible and it must belong to the requested monitor
@MainActor func getStubWorkspace(for monitor: Monitor) -> Workspace {
    getStubWorkspace(forPoint: monitor.rect.topLeftCorner)
}

@MainActor
private func getStubWorkspace(forPoint point: CGPoint) -> Workspace {
    if let prev = screenPointToPrevVisibleWorkspace[point].map({ Workspace.get(byName: $0) }),
       !prev.isVisible && prev.workspaceMonitor.rect.topLeftCorner == point && prev.forceAssignedMonitor == nil
    {
        return prev
    }
    if let candidate = Workspace.all
        .first(where: { !$0.isVisible && $0.workspaceMonitor.rect.topLeftCorner == point })
    {
        return candidate
    }
    return (1 ... Int.max).lazy
        .map { Workspace.get(byName: String($0)) }
        .first { $0.isEffectivelyEmpty && !$0.isVisible && !config.persistentWorkspaces.contains($0.name) && $0.forceAssignedMonitor == nil }
        .orDie("Can't create empty workspace")
}

final class Workspace: TreeNode, NonLeafTreeNodeObject, Hashable, Comparable {
    private(set) var name: String
    nonisolated private var nameLogicalSegments: StringLogicalSegments
    /// `assignedMonitorPoint` must be interpreted only when the workspace is invisible
    fileprivate var assignedMonitorPoint: CGPoint? = nil

    @MainActor
    private init(_ name: String) {
        self.name = name
        self.nameLogicalSegments = name.toLogicalSegments()
        super.init(parent: NilTreeNode.instance, adaptiveWeight: 0, index: 0)
    }

    @MainActor static var all: [Workspace] {
        workspaceNameToWorkspace.values.sorted()
    }

    @MainActor static func get(byName name: String) -> Workspace {
        if let existing = workspaceNameToWorkspace[name] {
            return existing
        } else {
            let workspace = Workspace(name)
            workspaceNameToWorkspace[name] = workspace
            return workspace
        }
    }

    nonisolated static func < (lhs: Workspace, rhs: Workspace) -> Bool {
        lhs.nameLogicalSegments < rhs.nameLogicalSegments
    }

    override func getWeight(_ targetOrientation: Orientation) -> CGFloat {
        workspaceMonitor.visibleRectPaddedByOuterGaps.getDimension(targetOrientation)
    }

    override func setWeight(_ targetOrientation: Orientation, _ newValue: CGFloat) {
        die("It's not possible to change weight of Workspace")
    }

    @MainActor
    var description: String {
        let description = [
            ("name", name),
            ("isVisible", String(isVisible)),
            ("isEffectivelyEmpty", String(isEffectivelyEmpty)),
            ("doKeepAlive", String(config.persistentWorkspaces.contains(name))),
        ].map { "\($0.0): '\(String(describing: $0.1))'" }.joined(separator: ", ")
        return "Workspace(\(description))"
    }

    @MainActor
    static func rename(
        _ workspace: Workspace,
        to newName: String,
        updateConfig: @MainActor (String, String) async throws -> Bool = updateConfigFile,
    ) async throws -> Bool {
        guard case .success = WorkspaceName.parse(newName) else { return false }
        guard workspaceNameToWorkspace[newName] == nil else { return false }
        let oldName = workspace.name
        // A name with a quote or backslash, or one that reads as a command separator, can't be written
        // into, or reliably found in, the config's command strings
        guard ![oldName, newName].contains(where: { name in
            commandSeparators.contains(name) || name.contains(where: { $0 == "'" || $0 == "\"" || $0 == "\\" })
        }) else { return false }

        // Update the config file on disk first, and reload it so keybindings and persistent
        // workspaces pick up the new name. Keep the old name if either step fails
        guard try await updateConfig(oldName, newName) else { return false }

        // Now update the in-memory workspace object.
        // After config reload, a new workspace with newName may have been created by
        // garbageCollectUnusedWorkspaces. Remove it so we can re-key the original.
        workspaceNameToWorkspace.removeValue(forKey: newName)

        // Remove from hash-keyed collections before changing name (hash depends on name)
        let screenPoint = visibleWorkspaceToScreenPoint.removeValue(forKey: workspace)

        // Update the workspace name
        workspaceNameToWorkspace.removeValue(forKey: oldName)
        workspace.name = newName
        workspace.nameLogicalSegments = newName.toLogicalSegments()
        workspaceNameToWorkspace[newName] = workspace

        // Re-insert into hash-keyed collections
        if let screenPoint {
            visibleWorkspaceToScreenPoint[workspace] = screenPoint
        }

        // Update string-based workspace name references
        for (point, name) in screenPointToPrevVisibleWorkspace where name == oldName {
            screenPointToPrevVisibleWorkspace[point] = newName
        }

        // Update focus tracking
        updateFocusWorkspaceName(from: oldName, to: newName)

        // The cache stores workspaces by name. Restoring it would bring the old workspace back
        resetClosedWindowsCache()

        return true
    }

    @MainActor
    private static func updateConfigFile(oldWorkspaceName: String, newWorkspaceName: String) async throws -> Bool {
        guard case .file(let url) = findCustomConfigUrl() else { return true }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let updated = renameWorkspaceInConfig(contents, from: oldWorkspaceName, to: newWorkspaceName)
        // Check the rewrite before it reaches disk. It must parse, and must not leave a reference it
        // couldn't reach (an inline table, a dotted key), which would bring the old workspace back
        guard parseConfig(updated).errors.isEmpty,
              !configStillReferences(parseConfig(updated, mergeWithDefaults: false).config, workspace: oldWorkspaceName)
        else { return false }
        if updated == contents { return true }
        try writeConfigFile(updated, to: url)
        return try await reloadConfig()
    }

    @MainActor
    static func garbageCollectUnusedWorkspaces() {
        for name in config.persistentWorkspaces {
            _ = get(byName: name) // Make sure that all persistent workspaces are "cached"
        }
        workspaceNameToWorkspace = workspaceNameToWorkspace.filter { (_, workspace: Workspace) in
            config.persistentWorkspaces.contains(workspace.name) ||
                !workspace.isEffectivelyEmpty ||
                workspace.isVisible ||
                workspace.name == focus.workspace.name
        }
    }

    nonisolated static func == (lhs: Workspace, rhs: Workspace) -> Bool {
        check((lhs === rhs) == (lhs.name == rhs.name), "lhs: \(lhs) rhs: \(rhs)")
        return lhs === rhs
    }

    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(name) }
}

extension Workspace {
    @MainActor
    var isVisible: Bool { visibleWorkspaceToScreenPoint.keys.contains(self) }
    @MainActor
    var workspaceMonitor: Monitor {
        forceAssignedMonitor
            ?? visibleWorkspaceToScreenPoint[self]?.monitorApproximation
            ?? assignedMonitorPoint?.monitorApproximation
            ?? mainMonitor
    }
}

extension Monitor {
    @MainActor
    var activeWorkspace: Workspace {
        if let existing = screenPointToVisibleWorkspace[rect.topLeftCorner] {
            return existing
        }
        // What if monitor configuration changed? (frame.origin is changed)
        rearrangeWorkspacesOnMonitors()
        let point = rect.topLeftCorner
        if let existing = screenPointToVisibleWorkspace[point] {
            return existing
        }
        // This Monitor value is stale: it was captured before a display change and its screen is gone.
        // Rearranging again can't bring it back, so answer for the current screen nearest to it
        return screenPointToVisibleWorkspace.minBy { ($0.key - point).vectorLength }?.value
            ?? getStubWorkspace(forPoint: point)
    }

    @MainActor
    func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        rect.topLeftCorner.setActiveWorkspace(workspace)
    }
}

@MainActor
func gcMonitors(_ currentMonitors: [Monitor] = monitors) {
    if screenPointToVisibleWorkspace.count != currentMonitors.count {
        rearrangeWorkspacesOnMonitors(currentMonitors)
    }
    showFocusedWorkspace(currentMonitors)
}

/// Rearranging drops the workspace of a screen that went away from the visible set, and nothing else
/// moves focus off it. Left alone, layout would hide the focused window in a corner while it stays key.
/// Keep the user on the workspace they were in, shown on the monitor it now belongs to (the one nearest
/// to where it was), rather than switching them to whatever that monitor was showing.
@MainActor
private func showFocusedWorkspace(_ currentMonitors: [Monitor]) {
    // NSScreen can be empty during display reconfiguration. Resolving a saved monitor point
    // requires a current screen; retain focus and restore its workspace on the next refresh.
    guard !currentMonitors.isEmpty else { return }
    let workspace = focus.workspace
    if workspace.isVisible { return }
    let monitor = workspace.workspaceMonitor
    if !monitor.setActiveWorkspace(workspace) {
        _ = monitor.activeWorkspace.focusWorkspace()
    }
}

extension CGPoint {
    @MainActor
    fileprivate func setActiveWorkspace(_ workspace: Workspace) -> Bool {
        if !isValidAssignment(workspace: workspace, screen: self) {
            return false
        }
        if let prevMonitorPoint = visibleWorkspaceToScreenPoint[workspace] {
            visibleWorkspaceToScreenPoint.removeValue(forKey: workspace)
            screenPointToPrevVisibleWorkspace[prevMonitorPoint] =
                screenPointToVisibleWorkspace.removeValue(forKey: prevMonitorPoint)?.name
        }
        if let prevWorkspace = screenPointToVisibleWorkspace[self] {
            screenPointToPrevVisibleWorkspace[self] =
                screenPointToVisibleWorkspace.removeValue(forKey: self)?.name
            visibleWorkspaceToScreenPoint.removeValue(forKey: prevWorkspace)
        }
        visibleWorkspaceToScreenPoint[workspace] = self
        screenPointToVisibleWorkspace[self] = workspace
        workspace.assignedMonitorPoint = self
        return true
    }
}

@MainActor
private func rearrangeWorkspacesOnMonitors(_ currentMonitors: [Monitor] = monitors) {
    let newScreens = currentMonitors.map(\.rect.topLeftCorner)
    let newScreenToOldScreenMapping = mapNewScreensToOldScreens(
        oldScreens: Array(screenPointToVisibleWorkspace.keys),
        newScreens: newScreens,
    )

    let oldScreenPointToVisibleWorkspace = screenPointToVisibleWorkspace
    screenPointToVisibleWorkspace = [:]
    visibleWorkspaceToScreenPoint = [:]

    for newScreen in newScreens {
        if let existingVisibleWorkspace = newScreenToOldScreenMapping[newScreen].flatMap({ oldScreenPointToVisibleWorkspace[$0] }),
           newScreen.setActiveWorkspace(existingVisibleWorkspace)
        {
            continue
        }
        let stubWorkspace = getStubWorkspace(forPoint: newScreen)
        check(newScreen.setActiveWorkspace(stubWorkspace),
              "getStubWorkspace generated incompatible stub workspace (\(stubWorkspace)) for the monitor (\(newScreen)")
    }
}

/// Decides which old screen's workspace each new screen keeps showing after a display change. Each old
/// screen goes to its nearest new screen, and the closest one wins when several want the same screen.
/// The ones that lost then take the screens nobody claimed, nearest pair first, so a visible workspace
/// stays visible as long as there is a screen left for it.
func mapNewScreensToOldScreens(oldScreens: [CGPoint], newScreens: [CGPoint]) -> [CGPoint: CGPoint] {
    func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { (a - b).vectorLength }
    // Dictionary order isn't stable. Sort so that ties resolve the same way every time
    let oldScreens = oldScreens.sortedBy([\.x, \.y])
    var mapping: [CGPoint: CGPoint] = [:]
    var leftover: [CGPoint] = []
    for oldScreen in oldScreens {
        guard let newScreen = newScreens.minBy({ distance($0, oldScreen) }) else { continue }
        if let prevOldScreen = mapping[newScreen] {
            if distance(prevOldScreen, newScreen) <= distance(oldScreen, newScreen) {
                // newScreen has already been assigned to a closer oldScreen.
                leftover.append(oldScreen)
                continue
            }
            leftover.append(prevOldScreen)
        }
        mapping[newScreen] = oldScreen
    }
    var unclaimed = newScreens.filter { mapping[$0] == nil }
    while !leftover.isEmpty && !unclaimed.isEmpty {
        let pairs = leftover.flatMap { old in unclaimed.map { new in (old: old, new: new) } }
        let nearest = pairs.minByOrDie { distance($0.old, $0.new) }
        mapping[nearest.new] = nearest.old
        leftover.removeAll { $0 == nearest.old }
        unclaimed.removeAll { $0 == nearest.new }
    }
    return mapping
}

@MainActor
private func isValidAssignment(workspace: Workspace, screen: CGPoint) -> Bool {
    if let forceAssigned = workspace.forceAssignedMonitor, forceAssigned.rect.topLeftCorner != screen {
        return false
    } else {
        return true
    }
}

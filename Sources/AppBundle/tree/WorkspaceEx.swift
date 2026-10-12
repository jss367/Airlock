import Common

extension Workspace {
    @MainActor var rootTilingContainer: TilingContainer {
        let containers = children.filterIsInstance(of: TilingContainer.self)
        switch containers.count {
            case 0:
                let orientation: Orientation = switch config.defaultRootContainerOrientation {
                    case .horizontal: .h
                    case .vertical: .v
                    case .auto: workspaceMonitor.then { $0.width >= $0.height } ? .h : .v
                }
                return TilingContainer(parent: self, adaptiveWeight: 1, orientation, config.defaultRootContainerLayout, index: INDEX_BIND_LAST)
            case 1:
                return containers.singleOrNil().orDie()
            default:
                die("Workspace must contain zero or one tiling container as its child")
        }
    }

    var floatingWindows: [Window] {
        children.filterIsInstance(of: Window.self)
    }

    /// Creates the container if it doesn't exist. Read-only callers should use ``existingMacOsNativeFullscreenWindowsContainer``
    @MainActor var macOsNativeFullscreenWindowsContainer: MacosFullscreenWindowsContainer {
        existingMacOsNativeFullscreenWindowsContainer ?? MacosFullscreenWindowsContainer(parent: self)
    }

    @MainActor var existingMacOsNativeFullscreenWindowsContainer: MacosFullscreenWindowsContainer? {
        let containers = children.filterIsInstance(of: MacosFullscreenWindowsContainer.self)
        return containers.count <= 1 ? containers.first : dieT("Workspace must contain zero or one MacosFullscreenWindowsContainer")
    }

    /// Creates the container if it doesn't exist. Read-only callers should use ``existingMacOsNativeHiddenAppsWindowsContainer``
    @MainActor var macOsNativeHiddenAppsWindowsContainer: MacosHiddenAppsWindowsContainer {
        existingMacOsNativeHiddenAppsWindowsContainer ?? MacosHiddenAppsWindowsContainer(parent: self)
    }

    @MainActor var existingMacOsNativeHiddenAppsWindowsContainer: MacosHiddenAppsWindowsContainer? {
        let containers = children.filterIsInstance(of: MacosHiddenAppsWindowsContainer.self)
        return containers.count <= 1 ? containers.first : dieT("Workspace must contain zero or one MacosHiddenAppsWindowsContainer")
    }

    @MainActor var forceAssignedMonitor: Monitor? {
        guard let monitorDescriptions = config.workspaceToMonitorForceAssignment[name] else { return nil }
        let sortedMonitors = sortedMonitors
        return monitorDescriptions.lazy
            .compactMap { $0.resolveMonitor(sortedMonitors: sortedMonitors) }
            .first
    }
}

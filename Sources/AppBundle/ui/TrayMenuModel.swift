import AppKit
import Combine
import Common

@MainActor
public final class TrayMenuModel: ObservableObject {
    @MainActor public static let shared = TrayMenuModel()

    private var sessionObservation: AnyCancellable?

    private init() {
        sessionObservation = sessionCoordinator.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    @Published var trayText: String = ""
    @Published var trayItems: [TrayItem] = []
    var isEnabled: Bool { sessionCoordinator.isEnabled }
    @Published var workspaces: [WorkspaceViewModel] = []
    @Published var experimentalUISettings: ExperimentalUISettings = ExperimentalUISettings()
}

/// Marks a workspace with a window that was denied focus. See `FocusAttentionState`
let attentionMarker = "●"

@MainActor func updateTrayText() {
    let sortedMonitors = sortedMonitors
    let focus = focus
    // The most recent request of each workspace
    var attention: [String: FocusAttentionRequest] = [:]
    for request in focusAttention.pending where attention[request.workspaceName] == nil {
        attention[request.workspaceName] = request
    }
    let orderedWorkspaces = workspacesForUi()
    let workspaces = orderedWorkspaces.map {
        let apps = $0.allLeafWindowsRecursive.map { $0.app.name?.takeIf { !$0.isEmpty } }.filterNotNil().toSet()
        let dash = " - "
        let suffix = switch true {
            case !apps.isEmpty: dash + apps.sorted().joinTruncating(separator: ", ", length: 25)
            case $0.isVisible: dash + $0.workspaceMonitor.name
            default: ""
        }
        // The menu draws name + suffix, so the suffix is what says it there, and says who asked
        let attentionSuffix = attention[$0.name].map { request in
            let app = Window.get(byId: request.windowId)?.app.name?.takeIf { !$0.isEmpty }
            return " \(attentionMarker) " + (app.map { "\($0) wants focus" } ?? "wants focus")
        }
        let hasFullscreenWindows = $0.allLeafWindowsRecursive.contains { $0.isFullscreen }
        return WorkspaceViewModel(
            name: $0.name,
            suffix: suffix + (attentionSuffix ?? ""),
            isFocused: focus.workspace == $0,
            isEffectivelyEmpty: $0.isEffectivelyEmpty,
            isVisible: $0.isVisible,
            hasFullscreenWindows: hasFullscreenWindows,
            wantsAttention: attentionSuffix != nil,
        )
    }
    TrayMenuModel.shared.workspaces = workspaces
    let visibleText = sortedMonitors
        .map {
            let hasFullscreenWindows = $0.activeWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
            let activeWorkspaceName = hasFullscreenWindows ? "[\($0.activeWorkspace.name)]" : $0.activeWorkspace.name
            return ($0.activeWorkspace == focus.workspace && sortedMonitors.count > 1 ? "*" : "") +
                (attention[$0.activeWorkspace.name] != nil ? attentionMarker : "") + activeWorkspaceName
        }
        .joined(separator: " │ ")
    // The text styles show only the visible workspaces. A workspace that wants the user joins them
    let waitingText = workspaces.filter { $0.wantsAttention && !$0.isVisible }.map { attentionMarker + $0.name }
    TrayMenuModel.shared.trayText = (activeMode?.takeIf { $0 != mainModeId }?.first.map { "(\($0.uppercased())) " } ?? "") +
        ([visibleText] + waitingText).joined(separator: "  ")
    var items = sortedMonitors.map {
        let hasFullscreenWindows = $0.activeWorkspace.allLeafWindowsRecursive.contains { $0.isFullscreen }
        return TrayItem(
            type: .workspace,
            name: $0.activeWorkspace.name,
            isActive: $0.activeWorkspace == focus.workspace,
            hasFullscreenWindows: hasFullscreenWindows,
            wantsAttention: attention[$0.activeWorkspace.name] != nil,
        )
    }
    let mode = activeMode?.takeIf { $0 != mainModeId }?.first.map {
        TrayItem(type: .mode, name: $0.uppercased(), isActive: true, hasFullscreenWindows: false)
    }
    if let mode {
        items.insert(mode, at: 0)
    }
    TrayMenuModel.shared.trayItems = items
}

struct WorkspaceViewModel: Hashable {
    let name: String
    let suffix: String
    let isFocused: Bool
    let isEffectivelyEmpty: Bool
    let isVisible: Bool
    let hasFullscreenWindows: Bool
    /// A window on it was denied focus and the user hasn't been there since
    let wantsAttention: Bool
}

enum TrayItemType: String, Hashable {
    case mode
    case workspace
}

private let validLetters = "A" ... "Z"

struct TrayItem: Hashable, Identifiable {
    let type: TrayItemType
    let name: String
    let isActive: Bool
    let hasFullscreenWindows: Bool
    var wantsAttention: Bool = false
    var systemImageName: String? {
        // System image type is only valid for numbers 0 to 50 and single capital char workspace name
        if let number = Int(name) {
            if !(0 ... 50).contains(number) { return nil }
        } else if name.count == 1 {
            if !validLetters.contains(name) { return nil }
        } else {
            return nil
        }
        let lowercasedName = name.lowercased()
        switch type {
            case .mode:
                return "\(lowercasedName).circle"
            case .workspace:
                if isActive {
                    return "\(lowercasedName).square.fill"
                } else {
                    return "\(lowercasedName).square"
                }
        }
    }
    var id: String {
        return type.rawValue + name
    }
}

import AppKit
import Combine
import Common
import HotKey

// MARK: - Data Model

struct OverviewWindow: Identifiable {
    let id: UInt32 // windowId
    let appName: String
    /// The window's own title. Empty until it has been read, and for windows that have none
    var title: String
    let icon: NSImage?
    /// Where the window sits on its workspace's monitor, in unit coordinates. nil when macOS doesn't report it
    var unitFrame: CGRect? = nil
    /// Position in the window server's front-to-back order
    var stackingOrder: Int = 0

    var displayTitle: String { title.isEmpty ? appName : title }
}

struct OverviewWorkspace: Identifiable {
    var id: String { name }
    let name: String
    let isFocused: Bool
    var windows: [OverviewWindow]
    /// Width over height of the workspace's monitor
    var monitorAspectRatio: CGFloat = 1.6
}

/// What Return or a click opens
enum WorkspaceOverviewTarget: Equatable {
    case workspace(String)
    case window(UInt32)
}

// MARK: - Layout

enum WorkspaceOverviewLayout {
    static let horizontalPadding: CGFloat = 40
    static let tileSpacing: CGFloat = 16
    static let tilePadding: CGFloat = 8
    static let tileMinWidth: CGFloat = 250
    static let tileMaxWidth: CGFloat = 350
    static let cardThumbnailSize = CGSize(width: 180, height: 110)

    /// As many window tiles per row as fit at their minimum width. Up and Down move by this many windows
    static func gridColumns(availableWidth: CGFloat) -> Int {
        let usable = availableWidth - 2 * horizontalPadding
        return max(1, Int((usable + tileSpacing) / (tileMinWidth + tileSpacing)))
    }

    static func tileWidth(availableWidth: CGFloat, columns: Int) -> CGFloat {
        let usable = availableWidth - 2 * horizontalPadding - CGFloat(columns - 1) * tileSpacing
        return max(1, min(tileMaxWidth, floor(usable / CGFloat(columns))))
    }
}

// MARK: - Observable State

@MainActor
final class WorkspaceOverviewState: ObservableObject {
    @Published private(set) var workspaces: [OverviewWorkspace]
    @Published private(set) var selectedWorkspaceIndex: Int
    /// The selected window of the selected workspace, or nil while the selection is on the workspace bar
    @Published private(set) var selectedWindowIndex: Int?
    @Published var thumbnails: [UInt32: CGImage]
    let gridColumns: Int

    /// With dozens of persistent workspaces most are empty, so only the focused one is listed without windows
    init(workspaces: [OverviewWorkspace], thumbnails: [UInt32: CGImage] = [:], gridColumns: Int = 1) {
        let listed = workspaces.filter { $0.isFocused || !$0.windows.isEmpty }
        self.workspaces = listed
        self.selectedWorkspaceIndex = listed.firstIndex(where: \.isFocused) ?? 0
        self.thumbnails = thumbnails
        self.gridColumns = max(1, gridColumns)
    }

    var selectedWorkspace: OverviewWorkspace? { workspaces[safe: selectedWorkspaceIndex] }

    var selectedWindow: OverviewWindow? {
        selectedWindowIndex.flatMap { selectedWorkspace?.windows[safe: $0] }
    }

    var selectedTarget: WorkspaceOverviewTarget? {
        if let selectedWindow { return .window(selectedWindow.id) }
        return selectedWorkspace.map { .workspace($0.name) }
    }

    /// Every window, starting with the selected workspace's so the thumbnails on screen load first
    var windowIdsFromSelectedWorkspace: [UInt32] {
        let start = min(selectedWorkspaceIndex, workspaces.count)
        return (workspaces[start...] + workspaces[..<start]).flatMap { $0.windows.map(\.id) }
    }

    // MARK: Keyboard

    func move(_ direction: CardinalDirection) {
        guard let workspace = selectedWorkspace else { return }
        let count = workspace.windows.count
        guard let index = selectedWindowIndex else {
            switch direction {
                case .left: selectedWorkspaceIndex = max(0, selectedWorkspaceIndex - 1)
                case .right: selectedWorkspaceIndex = min(workspaces.count - 1, selectedWorkspaceIndex + 1)
                case .down: if count > 0 { selectedWindowIndex = 0 }
                case .up: break
            }
            return
        }
        switch direction {
            case .left: selectedWindowIndex = max(0, index - 1)
            case .right: selectedWindowIndex = min(count - 1, index + 1)
            // From the top row, back to the workspace bar
            case .up: selectedWindowIndex = index >= gridColumns ? index - gridColumns : nil
            case .down:
                if index + gridColumns < count {
                    selectedWindowIndex = index + gridColumns
                } else if index / gridColumns < (count - 1) / gridColumns {
                    selectedWindowIndex = count - 1 // The last row is shorter than this column
                }
        }
    }

    /// Tab and Shift+Tab: step through the selected workspace's windows, entering them from the workspace bar
    func cycleWindow(offset: Int) {
        guard let count = selectedWorkspace?.windows.count, count > 0 else { return }
        if let index = selectedWindowIndex {
            selectedWindowIndex = (index + offset % count + count) % count
        } else {
            selectedWindowIndex = offset < 0 ? count - 1 : 0
        }
    }

    // MARK: Titles

    /// Read each window's real title, handing over every title found
    func refreshWindowTitles(
        readTitle: @MainActor (UInt32) async -> String? = { id in
            guard let window = Window.get(byId: id) else { return nil }
            return try? await window.title
        },
        onTitle: @MainActor (UInt32, String) -> Void = { _, _ in },
    ) async {
        for windowId in windowIdsFromSelectedWorkspace {
            guard !Task.isCancelled else { return }
            guard let title = await readTitle(windowId),
                  !title.isEmpty, !Task.isCancelled
            else { continue }
            onTitle(windowId, title)
            setTitle(title, forWindow: windowId)
        }
    }

    func setTitle(_ title: String, forWindow windowId: UInt32) {
        for workspaceIndex in workspaces.indices {
            guard let windowIndex = workspaces[workspaceIndex].windows.firstIndex(where: { $0.id == windowId }) else { continue }
            if workspaces[workspaceIndex].windows[windowIndex].title != title {
                workspaces[workspaceIndex].windows[windowIndex].title = title
            }
            return
        }
    }
}

// MARK: - Keys

/// What a key does while the overview is open
enum WorkspaceOverviewKeyAction: Equatable {
    case move(CardinalDirection)
    case cycleWindow(offset: Int)
    case activate
    case close
}

/// The overview's action for a key press, or nil for keys it doesn't use
func workspaceOverviewKeyAction(keyCode: UInt16, hasShift: Bool) -> WorkspaceOverviewKeyAction? {
    switch keyCode {
        case 123: .move(.left)
        case 124: .move(.right)
        case 125: .move(.down)
        case 126: .move(.up)
        case 48: .cycleWindow(offset: hasShift ? -1 : 1) // Tab
        case 36, 76: .activate // Return, keypad Enter
        case 53: .close // Escape
        default: nil
    }
}

/// Whether the key is bound to `workspace-overview` in any mode of the config. The key that opens the
/// overview also closes it, even if its hotkey isn't delivered while the overview has the keyboard
func isWorkspaceOverviewShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, _ config: Config) -> Bool {
    let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    return config.modes.values.contains { mode in
        mode.bindings.values.contains { binding in
            binding.keyCode.carbonKeyCode == UInt32(keyCode) &&
                binding.modifiers.intersection(relevantModifiers) == modifiers.intersection(relevantModifiers) &&
                binding.commands.contains { $0 is WorkspaceOverviewCommand }
        }
    }
}

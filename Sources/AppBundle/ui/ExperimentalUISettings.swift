import SwiftUI

/// The menu bar style lives in UserDefaults rather than the config file. Settings → Appearance edits it.
struct ExperimentalUISettings {
    /// Shows the occupied workspaces, so the menu bar says where your windows are
    static let defaultDisplayStyle: MenuBarStyle = .i3Ordered

    var displayStyle: MenuBarStyle {
        get { Self.displayStyle(storedValue: UserDefaults.standard.string(forKey: ExperimentalUISettingsItems.displayStyle.rawValue)) }
        set {
            UserDefaults.standard.setValue(newValue.rawValue, forKey: ExperimentalUISettingsItems.displayStyle.rawValue)
            UserDefaults.standard.synchronize()
        }
    }

    /// A stored choice wins. The default applies only when nothing valid is stored.
    static func displayStyle(storedValue: String?) -> MenuBarStyle {
        storedValue.flatMap(MenuBarStyle.init(rawValue:)) ?? defaultDisplayStyle
    }
}

enum MenuBarStyle: String, CaseIterable, Identifiable, Equatable, Hashable {
    case monospacedText
    case systemText
    case squares
    case i3
    case i3Ordered
    var id: String { rawValue }
    var title: String {
        switch self {
            case .monospacedText: "Monospaced text"
            case .systemText: "System font text"
            case .squares: "Squares"
            case .i3: "Squares, others grouped"
            case .i3Ordered: "Squares, in workspace order"
        }
    }
    var summary: String {
        switch self {
            case .monospacedText, .systemText: "The workspace shown on each monitor, as text."
            case .squares: "The workspace shown on each monitor."
            case .i3: "The workspace shown on each monitor, then the other workspaces that have windows."
            case .i3Ordered: "Every workspace that has windows or is shown on a monitor, in workspace order."
        }
    }
}

enum ExperimentalUISettingsItems: String {
    case displayStyle
}

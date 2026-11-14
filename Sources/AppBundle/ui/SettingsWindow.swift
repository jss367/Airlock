import AppKit
import Common
import SwiftUI

enum SettingsTab: Hashable {
    case general, shortcuts, appearance
}

/// The two views of the Shortcuts tab
enum ShortcutsView: Hashable {
    case list, keyboard
}

let settingsWindowWillClose = Notification.Name("AirlockSettingsWindowWillClose")

/// What the Settings window shows. Lives outside the view, so a command or menu item can open
/// the window on a particular tab and reopening keeps the last one.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
    @Published var shortcutsView: ShortcutsView = .list
}

/// Opens the Settings window, on `tab` if given and on the last used tab otherwise.
@MainActor
func showSettings(_ tab: SettingsTab? = nil, shortcutsView: ShortcutsView? = nil) {
    // The General tab can pause and resume. See `runEnableCommandFromUi`
    rememberExternalAppForUiResume(NSWorkspace.shared.frontmostApplication)
    let navigation = SettingsNavigation.shared
    if let tab { navigation.tab = tab }
    if let shortcutsView { navigation.shortcutsView = shortcutsView }
    let controller = SettingsWindowController.shared
    controller.installContentIfNeeded()
    controller.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    controller.window?.makeKeyAndOrderFront(nil)
}

// The entry points of the three windows that Settings replaced. Each opens the tab that took its place.
// periphery:ignore
@MainActor func showFeatureSettings() { showSettings(.general) }
// periphery:ignore
@MainActor func showKeybindingsHelp() { showSettings(.shortcuts, shortcutsView: .list) }
// periphery:ignore
@MainActor func showKeyboardVisualizer() { showSettings(.shortcuts, shortcutsView: .keyboard) }

private final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    @MainActor static let shared: SettingsWindowController = {
        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false,
        )
        window.title = "\(airlockAppName) Settings"
        window.center()
        window.isReleasedWhenClosed = false
        let controller = SettingsWindowController(window: window)
        window.delegate = controller
        return controller
    }()

    /// The views observe TrayMenuModel, which every config reload and enable/disable republishes,
    /// so the controls stay current while the window is open
    @MainActor func installContentIfNeeded() {
        guard let window, window.contentView as? NSHostingView<SettingsContent> == nil else { return }
        let size = window.contentRect(forFrameRect: window.frame).size
        window.contentView = NSHostingView(rootView: SettingsContent(navigation: .shared, model: .shared))
        // Keep the size the window had when it was closed
        window.setContentSize(size)
    }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.post(name: settingsWindowWillClose, object: nil)
        // Dropping the hosting view tears down the views, which stops the keyboard's refresh timer
        window?.contentView = nil
    }
}

/// Airlock is an agent app with no main menu, so nothing else gives the window ⌘W
private final class SettingsWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w"
        {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct SettingsContent: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var model: TrayMenuModel

    var body: some View {
        TabView(selection: $navigation.tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralSettingsPane(model: model)
            }
            Tab("Shortcuts", systemImage: "keyboard", value: SettingsTab.shortcuts) {
                ShortcutsSettingsPane(navigation: navigation, model: model)
            }
            Tab("Appearance", systemImage: "paintbrush", value: SettingsTab.appearance) {
                AppearanceSettingsPane(model: model)
            }
        }
        .frame(minWidth: settingsMinWidth, minHeight: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// The keyboard on the Shortcuts tab doesn't shrink, so the window can't get narrower than it
let settingsMinWidth: CGFloat = 880

// MARK: - Shared pieces

/// A scrolling tab body. Form-like tabs keep a readable width in a wide window.
struct SettingsPane<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                content()
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
    }
}

/// A titled card of rows
struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1),
            )
        }
    }
}

/// A title, a description, and a control on the right. With `disabledReason` set, the control
/// is disabled and the reason is shown under the description.
struct SettingsRow<Control: View>: View {
    let title: String
    let summary: String
    var disabledReason: String? = nil
    @ViewBuilder let control: () -> Control
    @Environment(\.isEnabled) private var isEnabled: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isEnabled && disabledReason == nil ? .primary : .secondary)
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let disabledReason { SettingsNotice(text: disabledReason) }
            }
            Spacer(minLength: 0)
            control()
                .disabled(disabledReason != nil)
        }
    }
}

/// Why something on the tab is unavailable
struct SettingsNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

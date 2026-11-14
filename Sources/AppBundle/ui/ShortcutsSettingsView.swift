import SwiftUI

/// The Shortcuts tab: the searchable list of bindings and the keyboard that shows and edits them.
struct ShortcutsSettingsPane: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var model: TrayMenuModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("View", selection: $navigation.shortcutsView) {
                    Label("List", systemImage: "list.bullet").tag(ShortcutsView.list)
                    Label("Keyboard", systemImage: "keyboard").tag(ShortcutsView.keyboard)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            switch navigation.shortcutsView {
                case .list: KeybindingsListView(model: model)
                case .keyboard: KeyboardVisualizerView()
            }
        }
    }

    private var hint: String {
        switch navigation.shortcutsView {
            case .list: "Every key binding in your config, by mode."
            case .keyboard: "What each key does with a modifier held. Click a key to assign an app to it."
        }
    }
}

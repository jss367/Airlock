import AppKit
import SwiftUI

struct KeyCapView: View {
    let key: PhysicalKey
    let bindingInfo: KeyBindingInfo
    let baseKeySize: CGFloat
    var onTap: (() -> Void)? = nil

    @State private var isHovered: Bool = false
    @State private var showCommandPopover: Bool = false

    private var isNonBindable: Bool { key.id.hasPrefix("_") }
    private var keyWidth: CGFloat { key.widthMultiplier * baseKeySize }
    private let keyHeight: CGFloat = 48
    /// The smallest text that is still readable on a key cap
    private let labelFontSize: CGFloat = 10

    private var isTappable: Bool {
        guard !isNonBindable else { return false }
        switch bindingInfo {
            case .otherCommand: return false
            case .appLauncher, .unbound: return true
        }
    }

    private var isClickable: Bool {
        !isNonBindable
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.gray.opacity(0.4), lineWidth: 0.5),
                )

            if isNonBindable {
                nonBindableContent
            } else {
                bindingContent
            }
        }
        .frame(width: keyWidth, height: keyHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            if isClickable { isHovered = hovering }
        }
        .onTapGesture { activate() }
        .popover(isPresented: $showCommandPopover, arrowEdge: .bottom) {
            if case .otherCommand(let description) = bindingInfo {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Command")
                        .font(.caption.bold())
                        .foregroundStyle(.secondary)
                    Text(description)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                }
                .padding(10)
                .frame(maxWidth: 300)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(keyCapAccessibilityLabel(key: key, bindingInfo: bindingInfo))
        .accessibilityAddTraits(isClickable ? .isButton : [])
        .accessibilityAction { activate() }
    }

    private func activate() {
        switch bindingInfo {
            case .otherCommand:
                showCommandPopover = true
            case .appLauncher, .unbound:
                if isTappable { onTap?() }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var nonBindableContent: some View {
        Text(key.displayLabel)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var bindingContent: some View {
        switch bindingInfo {
            case .appLauncher(let appName, let appPath):
                appLauncherContent(appName: appName, appPath: appPath)
            case .otherCommand(let description):
                otherCommandContent(description: description)
            case .unbound:
                unboundContent
        }
    }

    @ViewBuilder
    private func appLauncherContent(appName: String, appPath: String) -> some View {
        VStack(spacing: 2) {
            if let icon = resolveAppIcon(appPath: appPath) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            // The tooltip has the full name
            Text(appName)
                .font(.system(size: labelFontSize))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private func otherCommandContent(description: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "gearshape")
                .font(.system(size: 12))
                .foregroundStyle(.primary)
            // The tooltip and the popover have the full command
            Text(description)
                .font(.system(size: labelFontSize))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 2)
    }

    @ViewBuilder
    private var unboundContent: some View {
        ZStack {
            Text(key.displayLabel)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            VStack {
                HStack {
                    Spacer()
                    Image(systemName: "plus")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.quaternary)
                        .padding(2)
                }
                Spacer()
            }
        }
    }

    // MARK: - Styling

    private var backgroundColor: Color {
        if isNonBindable {
            return Color.gray.opacity(0.12)
        }
        let hoverBoost: CGFloat = isHovered ? 0.08 : 0.0
        switch bindingInfo {
            case .appLauncher:
                return Color.accentColor.opacity(0.18 + hoverBoost)
            case .otherCommand:
                return Color.orange.opacity(0.15 + hoverBoost)
            case .unbound:
                return Color.gray.opacity(0.08 + hoverBoost)
        }
    }
}

/// What VoiceOver reads for a key cap: the key, then what it is bound to
func keyCapAccessibilityLabel(key: PhysicalKey, bindingInfo: KeyBindingInfo) -> String {
    // Modifier keys can't be bound. Their notation is internal and their label is a symbol
    let modifierNames = [
        "_capslock": "Caps Lock", "_lshift": "left Shift", "_rshift": "right Shift",
        "_fn": "Function", "_ctrl": "Control", "_option": "left Option",
        "_roption": "right Option", "_cmd": "left Command", "_rcmd": "right Command",
    ]
    if let name = modifierNames[key.id] { return "\(name) key" }
    if key.id.hasPrefix("_") { return "\(key.displayLabel) key" }
    // Notations name the key in words ("semicolon"), which reads better than its symbol
    return switch bindingInfo {
        case .appLauncher(let appName, _): "\(key.id), opens \(appName)"
        case .otherCommand(let description): "\(key.id), runs \(description)"
        case .unbound: "\(key.id), unbound"
    }
}

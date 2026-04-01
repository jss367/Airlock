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
                        .strokeBorder(Color.gray.opacity(0.4), lineWidth: 0.5)
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
        .onTapGesture {
            switch bindingInfo {
            case .otherCommand:
                showCommandPopover = true
            case .appLauncher, .unbound:
                if isTappable { onTap?() }
            }
        }
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
            Text(appName)
                .font(.system(size: 8))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    @ViewBuilder
    private func otherCommandContent(description: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
            Text(description)
                .font(.system(size: 7))
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

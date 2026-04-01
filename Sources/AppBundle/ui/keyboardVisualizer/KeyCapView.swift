import AppKit
import SwiftUI

struct KeyCapView: View {
    let key: PhysicalKey
    let bindingInfo: KeyBindingInfo
    let baseKeySize: CGFloat

    private var isNonBindable: Bool { key.id.hasPrefix("_") }
    private var keyWidth: CGFloat { key.widthMultiplier * baseKeySize }
    private let keyHeight: CGFloat = 48

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
        switch bindingInfo {
        case .appLauncher:
            return Color.accentColor.opacity(0.18)
        case .otherCommand:
            return Color.orange.opacity(0.15)
        case .unbound:
            return Color.gray.opacity(0.08)
        }
    }
}

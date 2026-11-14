import AppKit
import SwiftUI

/// The Appearance tab of the Settings window: the menu bar style and the focus flash outline.
struct AppearanceSettingsPane: View {
    @ObservedObject var model: TrayMenuModel

    var body: some View {
        SettingsPane {
            SettingsSection(title: "Menu bar") {
                ForEach(Array(MenuBarStyle.allCases.enumerated()), id: \.element) { index, style in
                    if index > 0 { Divider() }
                    styleRow(style)
                }
            }
            focusFlashSection
        }
    }

    private func styleRow(_ style: MenuBarStyle) -> some View {
        let isSelected = model.experimentalUISettings.displayStyle == style
        let color = AppearanceTheme.current == .dark ? Color.white : Color.black
        return Button {
            model.experimentalUISettings.displayStyle = style
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(style.title).font(.body.weight(.medium))
                    Text(style.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                MenuBarLabel(style: style, color: color)
                    .environmentObject(model)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var focusFlashSection: some View {
        let flash = config.focusFlash
        let disabledReason = unmetReason(.focusFlash, config)
        return SettingsSection(title: "Focus flash") {
            if let disabledReason { SettingsNotice(text: disabledReason) }
            Group {
                SettingsRow(title: "Color", summary: "The color of the outline drawn around the focused window.") {
                    DebouncedConfigValue(saved: normalizedAARRGGBB(flash.color)) {
                        setSettingsValue(table: "focus-flash", key: "color", value: "'\($0)'")
                    } control: { hex in
                        ColorPicker("Color", selection: colorBinding(hex), supportsOpacity: true)
                            .labelsHidden()
                    }
                }
                Divider()
                SettingsRow(title: "Width", summary: "How thick the outline is, in points.") {
                    DebouncedConfigValue(saved: flash.width) {
                        setSettingsValue(table: "focus-flash", key: "width", value: String($0))
                    } control: { width in
                        Stepper(value: width, in: 1 ... 40, step: 1) {
                            Text("\(width.wrappedValue.formatted()) pt").monospacedDigit()
                        }
                    }
                }
                Divider()
                SettingsRow(title: "Duration", summary: "How long the outline stays on screen, in milliseconds.") {
                    DebouncedConfigValue(saved: flash.durationMs) {
                        setSettingsValue(table: "focus-flash", key: "duration-ms", value: String($0))
                    } control: { duration in
                        Stepper(value: duration, in: 100 ... 5000, step: 50) {
                            Text("\(duration.wrappedValue) ms").monospacedDigit()
                        }
                    }
                }
            }
            .disabled(disabledReason != nil)
        }
    }

    private func colorBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { Color(nsColor: parseAARRGGBB(hex.wrappedValue) ?? .green) },
            set: { color in
                if let value = aarrggbbString(NSColor(color)) { hex.wrappedValue = value }
            },
        )
    }
}

/// Holds an edit locally and writes it after a pause, so dragging through colors or clicking
/// through steps costs one config write and reload instead of one per value.
private struct DebouncedConfigValue<Value: Equatable & Sendable, Control: View>: View {
    /// The value in the loaded config
    let saved: Value
    let write: @MainActor (Value) -> Void
    @ViewBuilder let control: (Binding<Value>) -> Control
    @State private var draft: Value?

    var body: some View {
        control(Binding(get: { draft ?? saved }, set: { draft = $0 }))
            .task(id: draft) {
                guard let draft, draft != saved else { return }
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled { write(draft) }
            }
            // The reload brought the edit back, so follow the config again
            .onChange(of: saved) { if draft == saved { draft = nil } }
    }
}

/// `0xAARRGGBB` as `[focus-flash] color` wants it, or nil if the color has no sRGB form.
func aarrggbbString(_ color: NSColor) -> String? {
    guard let color = color.usingColorSpace(.sRGB) else { return nil }
    let components = [color.alphaComponent, color.redComponent, color.greenComponent, color.blueComponent]
    return "0x" + components.map { String(format: "%02x", Int(($0 * 255).rounded().coerce(in: 0 ... 255))) }.joined()
}

/// The config's color respelled the way `aarrggbbString` writes it, so the two compare equal.
private func normalizedAARRGGBB(_ value: String) -> String {
    parseAARRGGBB(value).flatMap(aarrggbbString) ?? value
}

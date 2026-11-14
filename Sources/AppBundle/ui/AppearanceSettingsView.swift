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
    let control: (Binding<Value>) -> Control
    @StateObject private var edit: DebouncedConfigEdit<Value>

    init(saved: Value, write: @MainActor @escaping (Value) -> Void, @ViewBuilder control: @escaping (Binding<Value>) -> Control) {
        self.saved = saved
        self.control = control
        self._edit = StateObject(wrappedValue: DebouncedConfigEdit(write: write))
    }

    var body: some View {
        control(Binding(get: { edit.draft ?? saved }, set: { edit.set($0, saved: saved) }))
            .onReceive(NotificationCenter.default.publisher(for: settingsWindowWillClose)) { _ in edit.flush() }
            .onDisappear { edit.flush() }
            // The reload brought the edit back, so follow the config again
            .onChange(of: saved) { edit.synchronize(saved: saved) }
    }
}

/// A tab or window closing commits the visible edit before its debounce task is canceled.
@MainActor
final class DebouncedConfigEdit<Value: Equatable & Sendable>: ObservableObject {
    @Published private(set) var draft: Value?
    private var pending: Value?
    private var pendingWait: Task<Void, Never>?
    private let wait: @MainActor () async throws -> Void
    private let write: @MainActor (Value) -> Void

    init(
        wait: @MainActor @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(300)) },
        write: @MainActor @escaping (Value) -> Void,
    ) {
        self.wait = wait
        self.write = write
    }

    func set(_ value: Value, saved: Value) {
        draft = value
        pendingWait?.cancel()
        pendingWait = nil
        pending = value == saved ? nil : value
        guard pending != nil else { return }
        let wait = wait
        pendingWait = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do { try await wait() } catch { return }
            if !Task.isCancelled { self?.flush() }
        }
    }

    func flush() {
        pendingWait?.cancel()
        pendingWait = nil
        guard let value = pending else { return }
        pending = nil
        write(value)
    }

    func synchronize(saved: Value) {
        guard draft == saved else { return }
        draft = nil
        pending = nil
        pendingWait?.cancel()
        pendingWait = nil
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

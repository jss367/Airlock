import Common
import SwiftUI

private let welcomeShownKey = "airlock-welcome-shown"

/// Opens the welcome window with every step that applies now, the basics included
// periphery:ignore - Entry point for a menu item
@MainActor
func showWelcomeWindow() {
    let model = WelcomeModel.shared
    if model.step == nil {
        model.start(welcomeSteps(
            needsPermission: !AXIsProcessTrusted(),
            dockSettingNeedsAttention: autoSwooshNeedsAttention(),
            showBasics: true,
        ))
    }
    WelcomeWindowController.shared.present()
}

/// Startup calls this twice: while Accessibility access is missing, and again once the config is loaded.
/// The basics are shown on the first launch only
@MainActor
func showWelcomeWindowAtStartupIfNeeded() {
    let model = WelcomeModel.shared
    // Already open on the permission step, which moves on by itself
    if model.step != nil { return }
    let steps = welcomeSteps(
        needsPermission: !AXIsProcessTrusted(),
        dockSettingNeedsAttention: autoSwooshNeedsAttention(),
        showBasics: !UserDefaults.standard.bool(forKey: welcomeShownKey),
    )
    if steps.isEmpty { return }
    model.start(steps)
    WelcomeWindowController.shared.present()
}

// MARK: - Model

enum WelcomeStep: Equatable, Sendable {
    case permission, dockSetting, basics
}

func welcomeSteps(needsPermission: Bool, dockSettingNeedsAttention: Bool, showBasics: Bool) -> [WelcomeStep] {
    var steps: [WelcomeStep] = []
    if needsPermission { steps.append(.permission) }
    if dockSettingNeedsAttention { steps.append(.dockSetting) }
    if showBasics { steps.append(.basics) }
    return steps
}

@MainActor
final class WelcomeModel: ObservableObject {
    static let shared = WelcomeModel()

    @Published private(set) var steps: [WelcomeStep] = []
    @Published private(set) var index = 0
    /// Runs when the last step is done, to close the window
    var onFinish: @MainActor () -> Void = {}

    private let defaults: UserDefaults
    private let waitForPermission: @MainActor () async throws -> Void
    private var permissionWait: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, waitForPermission: @MainActor @escaping () async throws -> Void = waitForAccessibilityPermission) {
        self.defaults = defaults
        self.waitForPermission = waitForPermission
    }

    var step: WelcomeStep? { steps.getOrNil(atIndex: index) }

    func start(_ steps: [WelcomeStep]) {
        self.steps = steps
        index = 0
        enterStep()
    }

    func advance() {
        if index + 1 < steps.count {
            index += 1
            enterStep()
        } else {
            reset()
            onFinish()
        }
    }

    /// Also for a window the user closed. The steps that still apply come back on the next launch
    func reset() {
        steps = []
        index = 0
        enterStep()
    }

    private func enterStep() {
        permissionWait?.cancel()
        permissionWait = nil
        switch step {
            case .permission:
                let wait = waitForPermission
                permissionWait = Task { [weak self] in
                    do { try await wait() } catch { return }
                    if !Task.isCancelled { self?.advance() }
                }
            case .basics:
                defaults.set(true, forKey: welcomeShownKey)
            case .dockSetting, nil:
                break
        }
    }
}

// MARK: - Shortcuts

struct WelcomeShortcut: Equatable {
    let title: String
    /// Key notation as in the config, e.g. "option-1". nil if the config binds no key
    let keys: String?
    let detail: String
}

/// The three shortcuts of the basics step, read from the config
func welcomeShortcuts(_ config: Config) -> [WelcomeShortcut] {
    let bindings = activeBindings(config.modes[mainModeId]?.bindings ?? [:], config).values
    func workspaceShortcut(titlePrefix: String, command: String, _ workspace: (any Command) -> String?) -> WelcomeShortcut {
        let found: [(keys: String, workspace: String)] = bindings
            .compactMap { binding in
                binding.commands.singleOrNil().flatMap(workspace).map { (binding.descriptionWithKeyNotation, $0) }
            }
            .sorted {
                let lhs = (config.persistentWorkspaces.firstIndex(of: $0.workspace) ?? Int.max, $0.workspace, $0.keys)
                let rhs = (config.persistentWorkspaces.firstIndex(of: $1.workspace) ?? Int.max, $1.workspace, $1.keys)
                return lhs < rhs
            }
        guard let first = found.first else {
            let detail = config.enableKeyboardShortcuts
                ? "No key is bound. Add a '\(command)' binding to your config."
                : "Keyboard shortcuts are turned off."
            return WelcomeShortcut(title: "\(titlePrefix) a workspace", keys: nil, detail: detail)
        }
        let next = found.first { $0.workspace != first.workspace }
        let others = found.count(where: { $0.workspace != first.workspace })
        let detail = next.map { "\(shortcutSymbols($0.keys)) for workspace \($0.workspace)" + (others > 1 ? ", and so on" : "") }
        return WelcomeShortcut(title: "\(titlePrefix) workspace \(first.workspace)", keys: first.keys, detail: detail ?? "")
    }
    return [
        workspaceShortcut(titlePrefix: "Switch to", command: "workspace") {
            ($0 as? WorkspaceCommand)?.args.target.val.workspaceNameOrNil()?.raw
        },
        workspaceShortcut(titlePrefix: "Move the focused window to", command: "move-node-to-workspace") {
            ($0 as? MoveNodeToWorkspaceCommand)?.args.target.val.workspaceNameOrNil()?.raw
        },
        config.quickSwitcher.enabled
            ? WelcomeShortcut(
                title: "Open the quick switcher",
                keys: config.quickSwitcher.binding,
                detail: "Search workspaces and windows, then jump to one",
            )
            : WelcomeShortcut(
                title: "Open the quick switcher",
                keys: nil,
                detail: "Its key is turned off in your config. Use Quick Switcher in the menu bar menu.",
            ),
    ]
}

/// "option-shift-1" -> ["⌥", "⇧", "1"]
func shortcutKeyLabels(_ notation: String) -> [String] {
    let parts = notation.split(separator: "-").map(String.init)
    let modifiers = modifierSymbols.filter { parts.dropLast().contains($0.name) }.map(\.symbol)
    guard let key = parts.last else { return modifiers }
    return modifiers + [keySymbols[key] ?? (key.count == 1 ? key.uppercased() : key.capitalized)]
}

func shortcutSymbols(_ notation: String) -> String { shortcutKeyLabels(notation).joined() }

// In the order macOS shows them
private let modifierSymbols: [(name: String, symbol: String)] = [
    ("ctrl", "\u{2303}"),   // ⌃
    ("option", "\u{2325}"), // ⌥
    ("shift", "\u{21E7}"),  // ⇧
    ("cmd", "\u{2318}"),    // ⌘
]

private let keySymbols: [String: String] = [
    "enter": "\u{21A9}",     // ↩
    "tab": "\u{21E5}",       // ⇥
    "esc": "\u{238B}",       // ⎋
    "backspace": "\u{232B}", // ⌫
    "left": "\u{2190}",      // ←
    "right": "\u{2192}",     // →
    "up": "\u{2191}",        // ↑
    "down": "\u{2193}",      // ↓
    "minus": "\u{2212}",     // −
    "equal": "=",
    "slash": "/",
    "backslash": "\\",
    "comma": ",",
    "period": ".",
    "semicolon": ";",
    "quote": "'",
    "backtick": "`",
    "leftSquareBracket": "[",
    "rightSquareBracket": "]",
]

// MARK: - Window

private final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    @MainActor static let shared: WelcomeWindowController = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
        )
        window.title = "Welcome to Airlock"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: WelcomeContent(model: .shared, tray: .shared))
        let controller = WelcomeWindowController(window: window)
        window.delegate = controller
        WelcomeModel.shared.onFinish = { window.close() }
        return controller
    }()

    @MainActor func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        WelcomeModel.shared.reset()
    }
}

// MARK: - View

struct WelcomeContent: View {
    @ObservedObject var model: WelcomeModel
    /// Every config reload and workspace switch republishes TrayMenuModel, which keeps the basics current
    @ObservedObject var tray: TrayMenuModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                switch model.step {
                    case .permission: permissionStep
                    case .dockSetting: dockSettingStep
                    case .basics: basicsStep
                    case nil: EmptyView()
                }
            }
            .padding(20)
            Spacer(minLength: 0)
            Divider()
            HStack(spacing: 10) {
                switch model.step {
                    case .permission: permissionButtons
                    case .dockSetting: dockSettingButtons
                    case .basics: basicsButtons
                    case nil: EmptyView()
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: 540, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(
                        colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing,
                    ),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous),
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Welcome to Airlock")
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.steps.count > 1 {
                Text("Step \(model.index + 1) of \(model.steps.count)")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var subtitle: String {
        switch model.step {
            case .permission: "Airlock needs your permission to manage windows"
            case .dockSetting: "One macOS setting gets in the way"
            case .basics, nil: "The basics"
        }
    }

    // MARK: Permission

    @ViewBuilder private var permissionStep: some View {
        card {
            Text("Allow Accessibility access").font(.body.weight(.medium))
            paragraph("Airlock arranges, moves, and hides the windows of other apps. macOS allows that only for apps you turn on in the Accessibility settings.")
            Divider()
            paragraph("Turn on Airlock in System Settings → Privacy & Security → Accessibility. Airlock starts as soon as access is granted, with no relaunch.")
        }
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Waiting for access…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 4)
    }

    @ViewBuilder private var permissionButtons: some View {
        Button("Quit Airlock") {
            Task {
                defer { terminateApp() }
                await withErrorReporting("Restoring windows before quitting") {
                    try await terminationHandler.beforeTermination()
                }
            }
        }
        Spacer()
        Button("Open System Settings") { openAccessibilitySettings() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }

    // MARK: Dock setting

    @ViewBuilder private var dockSettingStep: some View {
        card {
            Text("Turn off automatic Space switching").font(.body.weight(.medium))
            paragraph("The macOS setting “When switching to an application, switch to a Space that has open windows for the application” is on. It interferes with Airlock workspace management.")
            Divider()
            paragraph("Airlock can turn it off for you. This restarts the Dock. You can also change it in System Settings → Desktop & Dock.")
        }
    }

    @ViewBuilder private var dockSettingButtons: some View {
        Button("Don’t Ask Again") {
            ignoreAutoSwoosh()
            model.advance()
        }
        Spacer()
        Button("Remind Me Later") { model.advance() }
        Button("Turn It Off") {
            // On failure, stay on this step. The error is already on screen
            if disableAutoSwoosh() { model.advance() }
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }

    // MARK: Basics

    @ViewBuilder private var basicsStep: some View {
        card {
            paragraph("A workspace is a group of windows, and each monitor shows one workspace at a time. Windows on other workspaces are hidden, not closed. They come back when you switch to their workspace.")
        }
        card {
            let shortcuts = welcomeShortcuts(config)
            ForEach(Array(shortcuts.enumerated()), id: \.offset) { index, shortcut in
                if index > 0 { Divider() }
                shortcutRow(shortcut)
            }
        }
        card {
            // Names what the user sees there, e.g. the "1"
            let current = tray.isEnabled ? tray.workspaces.first(where: \.isFocused).map { ", “\($0.name)” right now" } : nil
            paragraph("The Airlock item in the menu bar shows the current workspace\(current ?? ""). Click it to switch workspaces, see every shortcut, change settings, or pause Airlock.")
        }
    }

    @ViewBuilder private var basicsButtons: some View {
        Spacer()
        Button("Done") { model.advance() }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
    }

    private func shortcutRow(_ shortcut: WelcomeShortcut) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(shortcut.title).font(.body.weight(.medium))
                if !shortcut.detail.isEmpty { paragraph(shortcut.detail) }
            }
            Spacer(minLength: 0)
            if let keys = shortcut.keys {
                HStack(spacing: 4) {
                    ForEach(Array(shortcutKeyLabels(keys).enumerated()), id: \.offset) { _, label in
                        keycap(label)
                    }
                }
            } else {
                Text("Not set")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func keycap(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .frame(minWidth: 16)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1),
            )
    }

    // MARK: Building blocks

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func card(@ViewBuilder content: () -> some View) -> some View {
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

import AppKit
import Common
import Foundation
import HotKey
import TOMLKit

@MainActor private var hotkeys: [String: HotKey] = [:]

@MainActor func resetHotKeys() {
    // Explicitly unregister all hotkeys. We cannot always rely on destruction of the HotKey object to trigger
    // unregistration because we might be running inside a hotkey handler that is keeping its HotKey object alive.
    for (_, key) in hotkeys {
        key.isEnabled = false
    }
    hotkeys = [:]
    HotKeySuppressor.shared.unregisterAll()
}

extension HotKey {
    var isEnabled: Bool {
        get { !isPaused }
        set {
            if isEnabled != newValue {
                isPaused = !newValue
            }
        }
    }
}

/// True while Settings records a shortcut. Airlock's hotkeys are unregistered meanwhile: a registered
/// hotkey never reaches the window as a key event, so a key that is already bound couldn't be recorded
/// and would run its binding instead.
@MainActor private(set) var isRecordingShortcut = false

@MainActor func setRecordingShortcut(_ recording: Bool) {
    guard isRecordingShortcut != recording else { return }
    isRecordingShortcut = recording
    registerHotkeys(for: activeMode)
    registerQuickSwitcherHotkey()
}

@MainActor var activeMode: String? = mainModeId
@MainActor func activateMode(_ targetMode: String?, beforeEffects: @MainActor @escaping () async throws -> Void = {}, beforeStateChange: @MainActor () -> Bool = { true }, onCallbacksAdmitted: @MainActor () -> Void = {}) async throws {
    guard beforeStateChange() else { return }
    registerHotkeys(for: targetMode)
    let oldMode = activeMode
    activeMode = targetMode
    if oldMode != targetMode {
        broadcastEvent(.modeChanged(mode: targetMode))
        if !config.onModeChanged.isEmpty {
            guard let token: RunSessionGuard = .forCallback else { return }
            try await adoptResumeWindowBeforeModeCallbacks()
            try await runLightSession(.onModeChanged, token, beforeEffects: {
                try await validateResumeWindowBeforeModeEffects()
                try await beforeEffects()
            }) {
                onCallbacksAdmitted()
                _ = try await config.onModeChanged.runCmdSeq(.defaultEnv, .emptyStdin)
            }
        }
    }
}

/// The bindings whose hotkeys should be registered in `targetMode`: none while a shortcut is being recorded
@MainActor func bindingsToRegister(for targetMode: String?) -> [String: HotkeyBinding] {
    isRecordingShortcut ? [:] : hotkeyBindings(for: targetMode)
}

/// Registers the hotkeys of `targetMode` and unregisters every other one
@MainActor private func registerHotkeys(for targetMode: String?) {
    let targetBindings = bindingsToRegister(for: targetMode)
    for binding in targetBindings.values where !hotkeys.keys.contains(binding.descriptionWithKeyCode) {
        hotkeys[binding.descriptionWithKeyCode] = HotKey(key: binding.keyCode, modifiers: binding.modifiers, keyDownHandler: {
            Task {
                // Mode commands may still run after an intentional Pause in a command sequence.
                if let activeMode = hotkeyDispatchMode {
                    markUserInitiatedFocusChange()
                    broadcastEvent(.bindingTriggered(
                        mode: activeMode,
                        binding: binding.descriptionWithKeyNotation,
                    ))
                    await withErrorReporting("Running a keyboard shortcut", userMessage: "Airlock could not complete the keyboard shortcut.") {
                        try await runHotkeyCommandSession(
                            config.modes[activeMode]?.bindings[binding.descriptionWithKeyCode]?.commands ?? [],
                            modifiers: binding.modifiers,
                        )
                    }
                }
            }
        })
    }
    for (binding, key) in hotkeys {
        if targetBindings.keys.contains(binding) {
            key.isEnabled = true
        } else {
            key.isEnabled = false
        }
    }
    HotKeySuppressor.shared.unregisterAll()
    for (_, key) in hotkeys where !key.isPaused {
        if let k = key.keyCombo.key {
            HotKeySuppressor.shared.register(key: k, modifiers: key.keyCombo.modifiers)
        }
    }
    syncNativeAppSwitcherKeys()
}

/// The native app switcher hotkeys that Airlock's registered hotkeys sit on. See `NativeAppSwitcherKeys`
@MainActor
func claimedNativeAppSwitcherKeys(_ combos: [KeyCombo]) -> Set<NativeAppSwitcherKey> {
    Set(combos.compactMap { combo in combo.key.flatMap { NativeAppSwitcherKey(key: $0, modifiers: combo.modifiers) } })
}

/// Call after every change to the registered hotkeys
@MainActor
func syncNativeAppSwitcherKeys() {
    NativeAppSwitcherKeys.shared.sync(claimed: nativeAppSwitcherKeysToClaim())
}

/// The native app switcher hotkeys Airlock should hold right now: the ones its registered hotkeys sit
/// on. While a shortcut is being recorded it holds both, whether or not a binding uses them. Otherwise
/// pressing Cmd+Tab to record it would open the native switcher, which also takes Airlock out of focus
/// and ends the recording. The next sync after recording gives back the ones no binding claims.
@MainActor
func nativeAppSwitcherKeysToClaim() -> Set<NativeAppSwitcherKey> {
    if isRecordingShortcut { return Set(NativeAppSwitcherKey.allCases) }
    let combos = hotkeys.values.filter { !$0.isPaused }.map(\.keyCombo) + [quickSwitcherKeyCombo].compactMap(\.self)
    return claimedNativeAppSwitcherKeys(combos)
}

/// Registration and dispatch follow running state even if a command changes mode after Pause.
@MainActor
var hotkeyDispatchMode: String? { sessionCoordinator.isEnabled ? activeMode : mainModeId }

@MainActor
func hotkeyBindings(for targetMode: String?) -> [String: HotkeyBinding] {
    let bindings = sessionCoordinator.isEnabled
        ? targetMode.flatMap { config.modes[$0] }?.bindings ?? [:]
        : pausedBindings()
    return activeBindings(bindings, config)
}

/// Paused Airlock owns no hotkeys except the main-mode bindings that only run `enable`, so a key can resume it.
@MainActor
func pausedBindings() -> [String: HotkeyBinding] {
    guard !sessionCoordinator.isEnabled else { return [:] }
    return (config.modes[mainModeId]?.bindings ?? [:]).filter { $0.value.isEnableOnly }
}

/// Drops the bindings whose feature is switched off, so their keys go back to macOS.
/// Workspace app switching requires window management; other bindings use `enable-keyboard-shortcuts`.
func activeBindings(_ bindings: [String: HotkeyBinding], _ config: Config) -> [String: HotkeyBinding] {
    bindings.filter { $0.value.isAppSwitching ? config.enableWindowManagement && config.enableWorkspaceAppSwitching : config.enableKeyboardShortcuts }
}

struct HotkeyBinding: Equatable, Sendable {
    let modifiers: NSEvent.ModifierFlags
    let keyCode: Key
    let commands: [any Command]
    let descriptionWithKeyCode: String
    let descriptionWithKeyNotation: String
    /// The 'disabled' sentinel: removes the default binding for this key. Distinct from `[]`,
    /// which binds the key to nothing so the keystroke is swallowed instead of reaching macOS
    let isDisabled: Bool

    init(_ modifiers: NSEvent.ModifierFlags, _ keyCode: Key, _ commands: [any Command], descriptionWithKeyNotation: String, isDisabled: Bool = false) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.commands = commands
        self.isDisabled = isDisabled
        self.descriptionWithKeyCode = modifiers.isEmpty
            ? keyCode.toString()
            : modifiers.toString() + "-" + keyCode.toString()
        self.descriptionWithKeyNotation = descriptionWithKeyNotation
    }

    /// Runs only `enable` commands, so it stays registered while Airlock is paused.
    var isEnableOnly: Bool { runsOnlyEnable(commands) }

    /// Runs `focus app-next`, `focus same-app-next`, or their `prev` twins
    var isAppSwitching: Bool {
        commands.contains { command in
            guard let focus = command as? FocusCommand, case .appCycle = focus.args.target else { return false }
            return true
        }
    }

    static func == (lhs: HotkeyBinding, rhs: HotkeyBinding) -> Bool {
        lhs.modifiers == rhs.modifiers &&
            lhs.keyCode == rhs.keyCode &&
            lhs.descriptionWithKeyCode == rhs.descriptionWithKeyCode &&
            lhs.isDisabled == rhs.isDisabled &&
            lhs.commands.count == rhs.commands.count &&
            zip(lhs.commands, rhs.commands).allSatisfy { $0.equals($1) }
    }
}

func parseBindings(_ raw: TOMLValueConvertible, _ backtrace: TomlBacktrace, _ errors: inout [TomlParseError], _ mapping: [String: Key]) -> [String: HotkeyBinding] {
    guard let rawTable = raw.table else {
        errors += [expectedActualTypeError(expected: .table, actual: raw.type, backtrace)]
        return [:]
    }
    var result: [String: HotkeyBinding] = [:]
    for (binding, rawCommand): (String, TOMLValueConvertible) in rawTable {
        let backtrace = backtrace + .key(binding)
        let binding = parseBinding(binding, backtrace, mapping)
            .flatMap { modifiers, key -> ParsedToml<HotkeyBinding> in
                if rawCommand.string == "disabled" {
                    // 'disabled' sentinel: store a marker binding to remove the default
                    return .success(HotkeyBinding(modifiers, key, [], descriptionWithKeyNotation: binding, isDisabled: true))
                }
                return parseCommandOrCommands(rawCommand).toParsedToml(backtrace).map {
                    HotkeyBinding(modifiers, key, $0, descriptionWithKeyNotation: binding)
                }
            }
            .getOrNil(appendErrorTo: &errors)
        if let binding {
            if result.keys.contains(binding.descriptionWithKeyCode) {
                errors.append(.semantic(backtrace, "'\(binding.descriptionWithKeyCode)' Binding redeclaration"))
            }
            result[binding.descriptionWithKeyCode] = binding
        }
    }
    return result
}

func parseBinding(_ raw: String, _ backtrace: TomlBacktrace, _ mapping: [String: Key]) -> ParsedToml<(NSEvent.ModifierFlags, Key)> {
    let rawKeys = raw.split(separator: "-")
    let modifiers: ParsedToml<NSEvent.ModifierFlags> = rawKeys.dropLast()
        .mapAllOrFailure {
            modifiersMap[String($0)].orFailure(.semantic(backtrace, "Can't parse modifiers in '\(raw)' binding"))
        }
        .map { NSEvent.ModifierFlags($0) }
    let key: ParsedToml<Key> = rawKeys.last.flatMap { mapping[String($0)] }
        .orFailure(.semantic(backtrace, "Can't parse the key in '\(raw)' binding"))
    return modifiers.flatMap { modifiers -> ParsedToml<(NSEvent.ModifierFlags, Key)> in
        key.flatMap { key -> ParsedToml<(NSEvent.ModifierFlags, Key)> in
            .success((modifiers, key))
        }
    }
}

func runsOnlyEnable(_ commands: [any Command]) -> Bool {
    !commands.isEmpty && commands.allSatisfy { $0 is EnableCommand }
}

/// The modifiers of the hotkey whose commands are running. Nil for commands that came from
/// anywhere else, such as the CLI. By the time a command runs the keys may already be up, so
/// this is how it learns what was held to start it
@TaskLocal var runningHotkeyModifiers: NSEvent.ModifierFlags? = nil

/// The same command-session path used by registered hotkeys, without key registration in tests.
@MainActor
func runHotkeyCommandSession(_ commands: [any Command], modifiers: NSEvent.ModifierFlags? = nil) async throws {
    try await $runningHotkeyModifiers.withValue(modifiers) {
        // Like `airlock enable` over the socket, an enable-only binding remains admissible while paused.
        guard sessionCoordinator.isEnabled || runsOnlyEnable(commands) else { return }
        if !sessionCoordinator.isEnabled {
            try await runEnableCommandsWithFocusAdoption(commands.compactMap { $0 as? EnableCommand }, event: .hotkeyBinding, syncFocusBeforeBody: false)
            return
        }
        let prepared = PreparedCommandSession(commands)
        try await runLightSession(.hotkeyBinding, prepared.admission) {
            _ = try await prepared.run(.defaultEnv, .emptyStdin)
        }
    }
}

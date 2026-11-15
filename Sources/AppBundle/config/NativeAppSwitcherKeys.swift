import AppKit
import Common
import HotKey
import PrivateApi

/// The window server's own hotkeys for the macOS app switcher
enum NativeAppSwitcherKey: Int32, CaseIterable, Sendable {
    case commandTab = 1
    case commandShiftTab = 2

    /// The native hotkey that a hotkey on `key` with `modifiers` competes with, if any
    init?(key: Key, modifiers: NSEvent.ModifierFlags) {
        guard key == .tab else { return nil }
        switch modifiers.intersection([.command, .shift, .option, .control]) {
            case .command: self = .commandTab
            case [.command, .shift]: self = .commandShiftTab
            default: return nil
        }
    }
}

/// macOS keeps Cmd+Tab for its own app switcher: a hotkey on that key registers without error and never fires.
/// So Airlock switches the native hotkey off while one of its own hotkeys claims the key, and back on when none does.
///
/// The switch outlives the process, so a key Airlock switched off is remembered in `store`. A later launch that no
/// longer claims the key (after a crash, say) then gives it back instead of leaving Cmd+Tab dead until logout.
@MainActor
final class NativeAppSwitcherKeys {
    struct System {
        var isEnabled: @MainActor (NativeAppSwitcherKey) -> Bool
        var setEnabled: @MainActor (NativeAppSwitcherKey, Bool) -> Void

        static let real = System(
            isEnabled: { CGSIsSymbolicHotKeyEnabled($0.rawValue) },
            setEnabled: { _ = CGSSetSymbolicHotKeyEnabled($0.rawValue, $1) },
        )
        /// Unit tests register real hotkeys and must leave the developer's Cmd+Tab alone
        static let inert = System(isEnabled: { _ in true }, setEnabled: { _, _ in })
    }

    struct Store {
        var load: @MainActor () -> Set<NativeAppSwitcherKey>
        var save: @MainActor (Set<NativeAppSwitcherKey>) -> Bool

        static let preferences = Store(
            load: {
                let raw = CFPreferencesCopyAppValue(storeKey as CFString, kCFPreferencesCurrentApplication) as? [Int] ?? []
                return Set(raw.compactMap { Int32(exactly: $0).flatMap(NativeAppSwitcherKey.init(rawValue:)) })
            },
            save: {
                CFPreferencesSetAppValue(storeKey as CFString, $0.map { Int($0.rawValue) }.sorted() as CFArray, kCFPreferencesCurrentApplication)
                // Recovery must reach disk before disabling a key, not await an asynchronous defaults write.
                return CFPreferencesAppSynchronize(kCFPreferencesCurrentApplication)
            },
        )
        private static let storeKey = "nativeAppSwitcherKeysSwitchedOff"
    }

    static let shared: NativeAppSwitcherKeys = isUnitTest
        ? NativeAppSwitcherKeys(system: .inert, store: .inMemory())
        : NativeAppSwitcherKeys(system: .real, store: .preferences)

    private let system: System
    private let store: Store

    init(system: System, store: Store) {
        self.system = system
        self.store = store
    }

    /// Switches off the native hotkeys in `claimed` and gives back the ones Airlock switched off and no longer claims.
    /// A key that something else already switched off is left alone and never given back by Airlock
    func sync(claimed: Set<NativeAppSwitcherKey>) {
        var switchedOff = store.load()
        for key in NativeAppSwitcherKey.allCases {
            if claimed.contains(key) {
                if system.isEnabled(key) {
                    // Write ahead: a crash immediately after the WindowServer call must still be recoverable.
                    switchedOff.insert(key)
                    guard store.save(switchedOff) else {
                        switchedOff.remove(key)
                        continue
                    }
                    system.setEnabled(key, false)
                    if system.isEnabled(key) {
                        // The disable failed. Do not claim a key we never switched off.
                        switchedOff.remove(key)
                        _ = store.save(switchedOff)
                    }
                }
            } else if switchedOff.contains(key) {
                system.setEnabled(key, true)
                if system.isEnabled(key) {
                    // Keep ownership until restoration succeeds, so a later sync/launch can retry.
                    switchedOff.remove(key)
                    _ = store.save(switchedOff)
                }
            }
        }
    }

    /// Gives back every native hotkey Airlock switched off. For termination
    func restoreAll() {
        sync(claimed: [])
    }
}

extension NativeAppSwitcherKeys.Store {
    @MainActor static func inMemory() -> Self {
        var keys: Set<NativeAppSwitcherKey> = []
        return Self(load: { keys }, save: { keys = $0; return true })
    }
}

/// Dispatch sources keep all Swift, preferences and WindowServer work out of POSIX signal context.
/// Fatal signals retain their default disposition; their recovery record is applied at the next launch.
@MainActor private var nativeAppSwitcherSignalSources: [DispatchSourceSignal] = []

@MainActor
func restoreNativeAppSwitcherKeysOnExit() {
    guard !isUnitTest else { return }
    configureNativeAppSwitcherExitHandling(
        restore: { NativeAppSwitcherKeys.shared.restoreAll() },
        onTermination: { action in
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { action() }
            }
        },
        onSignal: { received, action in
            signal(received, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: received, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { action() } }
            nativeAppSwitcherSignalSources.append(source)
            source.resume()
        },
        terminateBySignal: { received in
            signal(received, SIG_DFL)
            raise(received)
        },
    )
}

/// Recovery precedes the Accessibility wait: a previous crash must not leave Cmd+Tab disabled
/// while this launch waits for permission. Injected hooks let tests exercise the lifecycle without
/// installing process signal handlers, changing preferences, or calling WindowServer.
@MainActor
func configureNativeAppSwitcherExitHandling(
    restore: @MainActor @escaping () -> Void,
    onTermination: (@MainActor @escaping () -> Void) -> Void,
    onSignal: (Int32, @MainActor @escaping () -> Void) -> Void,
    terminateBySignal: @MainActor @escaping (Int32) -> Void,
) {
    restore()
    onTermination(restore)
    for received in [SIGTERM, SIGHUP] {
        onSignal(received) {
            restore()
            terminateBySignal(received)
        }
    }
}

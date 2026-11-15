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
        var save: @MainActor (Set<NativeAppSwitcherKey>) -> Void

        static let userDefaults = Store(
            load: {
                let raw = UserDefaults.standard.array(forKey: storeKey) as? [Int] ?? []
                return Set(raw.compactMap { NativeAppSwitcherKey(rawValue: Int32($0)) })
            },
            save: { UserDefaults.standard.set($0.map { Int($0.rawValue) }.sorted(), forKey: storeKey) },
        )
        private static let storeKey = "nativeAppSwitcherKeysSwitchedOff"
    }

    static let shared: NativeAppSwitcherKeys = isUnitTest
        ? NativeAppSwitcherKeys(system: .inert, store: .inMemory())
        : NativeAppSwitcherKeys(system: .real, store: .userDefaults)

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
                    system.setEnabled(key, false)
                    switchedOff.insert(key)
                }
            } else if switchedOff.remove(key) != nil {
                system.setEnabled(key, true)
            }
        }
        store.save(switchedOff)
        keysToRestoreOnSignal = switchedOff.reduce(0) { $0 | 1 << $1.rawValue }
    }

    /// Gives back every native hotkey Airlock switched off. For termination
    func restoreAll() {
        sync(claimed: [])
    }
}

extension NativeAppSwitcherKeys.Store {
    @MainActor static func inMemory() -> Self {
        var keys: Set<NativeAppSwitcherKey> = []
        return Self(load: { keys }, save: { keys = $0 })
    }
}

/// Bit `rawValue` is set for each key Airlock has switched off. Written on the main thread, read by the signal
/// handler, which can't touch main-actor state
nonisolated(unsafe) private var keysToRestoreOnSignal: Int32 = 0

/// Gives the native app switcher back when Airlock stops without running its termination handler:
/// `NSApplication.terminate` from outside Airlock's own Quit, a kill, or a crash
@MainActor
func restoreNativeAppSwitcherKeysOnExit() {
    NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { NativeAppSwitcherKeys.shared.restoreAll() }
    }
    for fatalSignal in [SIGTERM, SIGHUP, SIGTRAP, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE] {
        signal(fatalSignal, { received in
            for key in NativeAppSwitcherKey.allCases where keysToRestoreOnSignal & (1 << key.rawValue) != 0 {
                _ = CGSSetSymbolicHotKeyEnabled(key.rawValue, true)
            }
            // Die the way the signal would have without this handler, so crash reports stay intact
            signal(received, SIG_DFL)
            raise(received)
        } as sig_t)
    }
}

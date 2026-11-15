@testable import AppBundle
import AppKit
import Common
import HotKey
import XCTest

@MainActor
final class NativeAppSwitcherKeysTest: XCTestCase {
    /// Stands in for the window server: which native hotkeys are on, and every switch Airlock flipped
    @MainActor private final class FakeSystem {
        var enabled: Set<NativeAppSwitcherKey> = Set(NativeAppSwitcherKey.allCases)
        var calls: [String] = []
        var refusesEnable = false
        var refusesDisable = false

        var system: NativeAppSwitcherKeys.System {
            NativeAppSwitcherKeys.System(
                isEnabled: { self.enabled.contains($0) },
                setEnabled: { key, isEnabled in
                    self.calls.append("\(key) \(isEnabled ? "on" : "off")")
                    if isEnabled, self.refusesEnable { return }
                    if !isEnabled, self.refusesDisable { return }
                    if isEnabled { self.enabled.insert(key) } else { self.enabled.remove(key) }
                },
            )
        }
    }

    func testOnlyPlainCommandTabCombosCompeteWithTheNativeSwitcher() {
        assertEquals(NativeAppSwitcherKey(key: .tab, modifiers: .command), .commandTab)
        assertEquals(NativeAppSwitcherKey(key: .tab, modifiers: [.command, .shift]), .commandShiftTab)
        // Flags that aren't modifiers of the combo don't change which key it is
        assertEquals(NativeAppSwitcherKey(key: .tab, modifiers: [.command, .capsLock]), .commandTab)
        assertEquals(NativeAppSwitcherKey(key: .tab, modifiers: .option), nil)
        assertEquals(NativeAppSwitcherKey(key: .tab, modifiers: [.command, .option]), nil)
        assertEquals(NativeAppSwitcherKey(key: .grave, modifiers: .command), nil)
    }

    func testClaimedKeysComeFromEveryRegisteredCombo() {
        let combos = [
            KeyCombo(key: .tab, modifiers: [.command, .shift]),
            KeyCombo(key: .grave, modifiers: .command),
            KeyCombo(key: .space, modifiers: .option),
        ]
        assertEquals(claimedNativeAppSwitcherKeys(combos), [.commandShiftTab])
        assertEquals(claimedNativeAppSwitcherKeys([]), [])
    }

    func testClaimedKeysAreSwitchedOffAndGivenBack() {
        let fake = FakeSystem()
        let keys = NativeAppSwitcherKeys(system: fake.system, store: .inMemory())

        keys.sync(claimed: [.commandTab, .commandShiftTab])
        assertEquals(fake.enabled, [])

        // Syncing again with the same claim flips nothing
        fake.calls = []
        keys.sync(claimed: [.commandTab, .commandShiftTab])
        assertEquals(fake.calls, [])

        keys.sync(claimed: [.commandTab])
        assertEquals(fake.enabled, [.commandShiftTab])

        keys.restoreAll()
        assertEquals(fake.enabled, Set(NativeAppSwitcherKey.allCases))
    }

    func testUnclaimedKeysAreNeverTouched() {
        let fake = FakeSystem()
        let keys = NativeAppSwitcherKeys(system: fake.system, store: .inMemory())
        keys.sync(claimed: [])
        keys.restoreAll()
        assertEquals(fake.calls, [])
    }

    func testAKeySomethingElseSwitchedOffIsNotGivenBack() {
        let fake = FakeSystem()
        fake.enabled = [.commandShiftTab]
        let keys = NativeAppSwitcherKeys(system: fake.system, store: .inMemory())

        keys.sync(claimed: [.commandTab, .commandShiftTab])
        keys.restoreAll()

        assertEquals(fake.enabled, [.commandShiftTab])
        assertEquals(fake.calls, ["commandShiftTab off", "commandShiftTab on"])
    }

    func testANewLaunchGivesBackWhatAnEarlierOneLeftSwitchedOff() {
        let fake = FakeSystem()
        let store = NativeAppSwitcherKeys.Store.inMemory()
        // The first launch dies without restoring: the window server and the store both keep its switch
        NativeAppSwitcherKeys(system: fake.system, store: store).sync(claimed: [.commandTab])
        assertEquals(fake.enabled, [.commandShiftTab])

        // Still claimed after the relaunch: stays off, and is still Airlock's to give back
        let relaunched = NativeAppSwitcherKeys(system: fake.system, store: store)
        relaunched.sync(claimed: [.commandTab])
        assertEquals(fake.enabled, [.commandShiftTab])

        // App switching was turned off in the config before a third launch
        NativeAppSwitcherKeys(system: fake.system, store: store).sync(claimed: [])
        assertEquals(fake.enabled, Set(NativeAppSwitcherKey.allCases))
    }

    func testOwnershipIsSavedBeforeDisablingTheNativeKey() {
        let store = NativeAppSwitcherKeys.Store.inMemory()
        var recordedAtDisable: Set<NativeAppSwitcherKey> = []
        var enabled = true
        let system = NativeAppSwitcherKeys.System(isEnabled: { _ in enabled }, setEnabled: { _, value in
            if !value { recordedAtDisable = store.load() }
            enabled = value
        })
        NativeAppSwitcherKeys(system: system, store: store).sync(claimed: [.commandTab])
        assertEquals(recordedAtDisable, [.commandTab])
    }

    func testFailedRestorationKeepsOwnershipForALaterRetry() {
        let fake = FakeSystem()
        let store = NativeAppSwitcherKeys.Store.inMemory()
        let keys = NativeAppSwitcherKeys(system: fake.system, store: store)
        keys.sync(claimed: [.commandTab])
        fake.refusesEnable = true
        keys.restoreAll()
        assertEquals(store.load(), [.commandTab])
        assertEquals(fake.enabled, [.commandShiftTab])
        fake.refusesEnable = false
        keys.restoreAll()
        assertEquals(store.load(), [])
        assertEquals(fake.enabled, Set(NativeAppSwitcherKey.allCases))
    }

    func testFailedDisableDoesNotClaimAnEnabledNativeKey() {
        let fake = FakeSystem()
        fake.refusesDisable = true
        let store = NativeAppSwitcherKeys.Store.inMemory()
        NativeAppSwitcherKeys(system: fake.system, store: store).sync(claimed: [.commandTab])
        assertEquals(store.load(), [])
        assertEquals(fake.enabled, Set(NativeAppSwitcherKey.allCases))
    }

    func testFailedOwnershipSaveNeverDisablesTheNativeKey() {
        let fake = FakeSystem()
        let store = NativeAppSwitcherKeys.Store(load: { [] }, save: { _ in false })
        NativeAppSwitcherKeys(system: fake.system, store: store).sync(claimed: [.commandTab])
        assertEquals(fake.calls, [])
        assertEquals(fake.enabled, Set(NativeAppSwitcherKey.allCases))
    }

    func testStartupRecoveryPrecedesHandlerInstallationAndAnyPermissionWait() {
        let fake = FakeSystem()
        let store = NativeAppSwitcherKeys.Store.inMemory()
        NativeAppSwitcherKeys(system: fake.system, store: store).sync(claimed: [.commandTab])
        let relaunched = NativeAppSwitcherKeys(system: fake.system, store: store)
        configureNativeAppSwitcherExitHandling(restore: { relaunched.restoreAll() }, onTermination: { _ in
            assertEquals(fake.enabled, Set(NativeAppSwitcherKey.allCases))
            assertEquals(store.load(), [])
        }, onSignal: { _, _ in
            assertEquals(fake.enabled, Set(NativeAppSwitcherKey.allCases))
        }, terminateBySignal: { _ in XCTFail("Installing handlers must not terminate") })
        assertEquals(fake.enabled, Set(NativeAppSwitcherKey.allCases))
    }

    func testTerminationAndGracefulSignalsRestoreOutsideSignalContextBeforeExiting() {
        var events: [String] = []
        var termination: (@MainActor () -> Void)?
        var handlers: [Int32: @MainActor () -> Void] = [:]
        configureNativeAppSwitcherExitHandling(restore: { events.append("restore") }, onTermination: { termination = $0 }, onSignal: { handlers[$0] = $1 }, terminateBySignal: { events.append("exit \($0)") })
        assertEquals(events, ["restore"])
        // In particular, never replace the handlers for synchronous faults/crashes.
        assertEquals(Set(handlers.keys), [SIGTERM, SIGHUP])
        events = []
        termination?()
        assertEquals(events, ["restore"])
        for received in [SIGTERM, SIGHUP] {
            events = []
            handlers[received]?() // A fake dispatch-source delivery, not a real signal.
            assertEquals(events, ["restore", "exit \(received)"])
        }
    }

    func testUnitTestsNeverReachTheWindowServer() {
        // Tests register real hotkeys, cmd-tab among them. The shared instance must not flip the developer's switcher
        XCTAssertTrue(isUnitTest)
        NativeAppSwitcherKeys.shared.sync(claimed: [.commandTab])
        NativeAppSwitcherKeys.shared.restoreAll()
    }
}

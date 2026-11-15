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

        var system: NativeAppSwitcherKeys.System {
            NativeAppSwitcherKeys.System(
                isEnabled: { self.enabled.contains($0) },
                setEnabled: { key, isEnabled in
                    self.calls.append("\(key) \(isEnabled ? "on" : "off")")
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

    func testUnitTestsNeverReachTheWindowServer() {
        // Tests register real hotkeys, cmd-tab among them. The shared instance must not flip the developer's switcher
        XCTAssertTrue(isUnitTest)
        NativeAppSwitcherKeys.shared.sync(claimed: [.commandTab])
        NativeAppSwitcherKeys.shared.restoreAll()
    }
}

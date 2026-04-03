@testable import AppBundle
import Carbon
import HotKey
import XCTest

@MainActor
final class HotKeySuppressorTest: XCTestCase {
    override func setUp() {
        super.setUp()
        HotKeySuppressor.shared.unregisterAll()
    }

    override func tearDown() {
        HotKeySuppressor.shared.unregisterAll()
        super.tearDown()
    }

    // MARK: - Key Registration

    func testRegisterAddsKeyEntry() {
        HotKeySuppressor.shared.register(key: .s, modifiers: .option)
        let keys = HotKeySuppressor.shared.registeredKeys
        assertEquals(keys.count, 1)
        let entry = keys.first!
        assertEquals(entry.keyCode, Key.s.carbonKeyCode)
        assertEquals(entry.modifiers, NSEvent.ModifierFlags.option.carbonFlags)
    }

    func testRegisterMultipleKeys() {
        HotKeySuppressor.shared.register(key: .s, modifiers: .option)
        HotKeySuppressor.shared.register(key: .h, modifiers: .option)
        HotKeySuppressor.shared.register(key: .i, modifiers: [.option, .control, .command, .shift])
        assertEquals(HotKeySuppressor.shared.registeredKeys.count, 3)
    }

    func testRegisterDuplicateKeyIsIdempotent() {
        HotKeySuppressor.shared.register(key: .s, modifiers: .option)
        HotKeySuppressor.shared.register(key: .s, modifiers: .option)
        assertEquals(HotKeySuppressor.shared.registeredKeys.count, 1)
    }

    func testUnregisterAllClearsKeys() {
        HotKeySuppressor.shared.register(key: .s, modifiers: .option)
        HotKeySuppressor.shared.register(key: .h, modifiers: .option)
        HotKeySuppressor.shared.unregisterAll()
        assertEquals(HotKeySuppressor.shared.registeredKeys.count, 0)
    }

    // MARK: - KeyEntry matching

    func testKeyEntryEquality() {
        let a = HotKeySuppressor.KeyEntry(keyCode: Key.s.carbonKeyCode, modifiers: NSEvent.ModifierFlags.option.carbonFlags)
        let b = HotKeySuppressor.KeyEntry(keyCode: Key.s.carbonKeyCode, modifiers: NSEvent.ModifierFlags.option.carbonFlags)
        assertEquals(a, b)
    }

    func testKeyEntryDifferentModifiers() {
        let a = HotKeySuppressor.KeyEntry(keyCode: Key.s.carbonKeyCode, modifiers: NSEvent.ModifierFlags.option.carbonFlags)
        let b = HotKeySuppressor.KeyEntry(keyCode: Key.s.carbonKeyCode, modifiers: NSEvent.ModifierFlags.command.carbonFlags)
        assertNotEquals(a, b)
    }

    func testKeyEntryDifferentKeys() {
        let a = HotKeySuppressor.KeyEntry(keyCode: Key.s.carbonKeyCode, modifiers: NSEvent.ModifierFlags.option.carbonFlags)
        let b = HotKeySuppressor.KeyEntry(keyCode: Key.h.carbonKeyCode, modifiers: NSEvent.ModifierFlags.option.carbonFlags)
        assertNotEquals(a, b)
    }

    func testHyperModifierKeyEntry() {
        let hyper: NSEvent.ModifierFlags = [.option, .control, .command, .shift]
        HotKeySuppressor.shared.register(key: .i, modifiers: hyper)
        let entry = HotKeySuppressor.KeyEntry(keyCode: Key.i.carbonKeyCode, modifiers: hyper.carbonFlags)
        assertTrue(HotKeySuppressor.shared.registeredKeys.contains(entry))
    }

    // MARK: - Modifier masking (P2 regression test)

    func testRegisteredModifiersOnlyContainCanonicalBits() {
        // When we register with .option, the stored carbonFlags should only contain optionKey
        HotKeySuppressor.shared.register(key: .s, modifiers: .option)
        let entry = HotKeySuppressor.shared.registeredKeys.first!
        let canonicalMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)
        // Stored modifiers should equal themselves after masking (no extra bits)
        assertEquals(entry.modifiers, entry.modifiers & canonicalMask)
    }

    func testExtraModifierBitsShouldNotPreventMatch() {
        // This tests the scenario where raw Carbon events have extra modifier bits
        // (e.g., Fn key, Caps Lock) that aren't in our registered set.
        // The lookup in the callback masks these out before checking.
        HotKeySuppressor.shared.register(key: .s, modifiers: .option)

        let registered = HotKeySuppressor.shared.registeredKeys
        let canonicalMask = UInt32(cmdKey | shiftKey | optionKey | controlKey)

        // Simulate a raw event with option + extra bits (e.g., Fn key = 0x800000)
        let rawModsWithExtra = NSEvent.ModifierFlags.option.carbonFlags | 0x800000
        let maskedEntry = HotKeySuppressor.KeyEntry(
            keyCode: Key.s.carbonKeyCode,
            modifiers: rawModsWithExtra & canonicalMask,
        )
        assertTrue(registered.contains(maskedEntry))

        // Without masking, the lookup should fail (demonstrating why masking matters)
        let unmaskedEntry = HotKeySuppressor.KeyEntry(
            keyCode: Key.s.carbonKeyCode,
            modifiers: rawModsWithExtra,
        )
        XCTAssertFalse(registered.contains(unmaskedEntry))
    }
}

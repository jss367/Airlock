import AppKit
import Carbon
import CoreGraphics
import HotKey
import os

/// Placeholder for future keyboard event suppression.
///
/// Previously this used a CGEventTap with `.defaultTap` to suppress hotkey events
/// and prevent them from leaking through to focused apps. However, CGEventTap
/// suppression (returning nil) kills events before Carbon's `RegisterEventHotKey`
/// can process them — regardless of head-insert vs tail-append placement — which
/// breaks all hotkeys. The tap is now listen-only until a suppression approach
/// that doesn't interfere with Carbon hotkeys is found.
final class HotKeySuppressor: @unchecked Sendable {
    static let shared = HotKeySuppressor()

    private let lock = OSAllocatedUnfairLock<Set<KeyEntry>>(initialState: [])
    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    struct KeyEntry: Hashable, Sendable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    var registeredKeys: Set<KeyEntry> {
        lock.withLock { $0 }
    }

    @MainActor
    func register(key: Key, modifiers: NSEvent.ModifierFlags) {
        lock.withLock { _ = $0.insert(KeyEntry(
            keyCode: key.carbonKeyCode,
            modifiers: modifiers.carbonFlags
        )) }
        if eventTap == nil { install() }
    }

    @MainActor
    func unregisterAll() {
        lock.withLock { $0.removeAll() }
    }

    @MainActor
    private func install() {
        guard eventTap == nil else { return }
        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: hotKeySuppressorCallback,
            userInfo: nil
        )
        guard let eventTap else { return }
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }
}

/// Convert CGEventFlags to Carbon modifier flags for comparison with registered hotkeys.
private func cgFlagsToCarbonModifiers(_ flags: CGEventFlags) -> UInt32 {
    var carbon: UInt32 = 0
    if flags.contains(.maskCommand)   { carbon |= UInt32(cmdKey) }
    if flags.contains(.maskShift)     { carbon |= UInt32(shiftKey) }
    if flags.contains(.maskAlternate) { carbon |= UInt32(optionKey) }
    if flags.contains(.maskControl)   { carbon |= UInt32(controlKey) }
    return carbon
}

private func hotKeySuppressorCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = HotKeySuppressor.shared.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
    let carbonMods = cgFlagsToCarbonModifiers(event.flags)

    let entry = HotKeySuppressor.KeyEntry(keyCode: keyCode, modifiers: carbonMods)
    if HotKeySuppressor.shared.registeredKeys.contains(entry) {
        return nil // suppress — the Carbon hotkey handler will still fire
    }
    return Unmanaged.passUnretained(event)
}

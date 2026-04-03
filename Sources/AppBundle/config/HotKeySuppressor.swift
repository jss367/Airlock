import AppKit
import Carbon
import HotKey
import os

/// Suppresses raw keyboard events that match registered hotkeys, preventing them
/// from leaking through to focused applications (e.g. Chrome interpreting
/// Option+Shift+I from a Hyper+I combo as "Report an Issue").
///
/// Uses a Carbon event handler for `kEventRawKeyDown` / `kEventRawKeyUp`.
/// When a Carbon hotkey fires, two events are dispatched:
///   1. `kEventHotKeyPressed` — intercepted by the HotKey library
///   2. `kEventRawKeyDown` — would leak through to the focused app
/// By consuming the raw key events here we prevent the leak without
/// interfering with `kEventHotKeyPressed`.
final class HotKeySuppressor: @unchecked Sendable {
    static let shared = HotKeySuppressor()

    private let lock = OSAllocatedUnfairLock<Set<KeyEntry>>(initialState: [])
    private var eventHandlerRef: EventHandlerRef?

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
        if eventHandlerRef == nil { install() }
    }

    @MainActor
    func unregisterAll() {
        lock.withLock { $0.removeAll() }
    }

    @MainActor
    private func install() {
        guard eventHandlerRef == nil else { return }

        var eventSpec = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventRawKeyDown)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventRawKeyUp)),
        ]

        InstallEventHandler(
            GetEventDispatcherTarget(),
            carbonSuppressorCallback,
            eventSpec.count,
            &eventSpec,
            nil,
            &eventHandlerRef
        )
    }
}

private func carbonSuppressorCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var keyCode: UInt32 = 0
    GetEventParameter(
        event,
        EventParamName(kEventParamKeyCode),
        EventParamType(typeUInt32),
        nil,
        MemoryLayout<UInt32>.size,
        nil,
        &keyCode
    )

    var carbonMods: UInt32 = 0
    GetEventParameter(
        event,
        EventParamName(kEventParamKeyModifiers),
        EventParamType(typeUInt32),
        nil,
        MemoryLayout<UInt32>.size,
        nil,
        &carbonMods
    )

    let entry = HotKeySuppressor.KeyEntry(keyCode: keyCode, modifiers: carbonMods)
    if HotKeySuppressor.shared.registeredKeys.contains(entry) {
        return noErr // consume the event
    }
    return OSStatus(eventNotHandledErr) // let it propagate
}

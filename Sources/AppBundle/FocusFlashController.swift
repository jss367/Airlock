import AppKit
import Common

@MainActor
final class FocusFlashController {
    static let shared = FocusFlashController()

    private lazy var overlay = FocusFlashOverlay()

    /// Public entry point — fire a flash on the given window if it's eligible.
    /// Caller is responsible for the `enabled`/`mode` predicate; this method only
    /// handles "is this window flashable?" edge cases.
    func flash(window: Window?) {
        guard let window else { return }

        let cfg = config.focusFlash
        guard cfg.enabled else { return }

        // Skip non-real windows (popups, hidden-app windows) and native-
        // fullscreen windows (the panel can't reliably overlay a fullscreen
        // Space). The window's child→parent relation tells us its container
        // kind. We treat "no parent" as a skip too — an unbound window
        // shouldn't be flashed.
        guard let parent = window.parent else { return }
        switch getChildParentRelationOrNil(child: window, parent: parent) {
            case .macosPopupWindow, .macosNativeHiddenAppWindow, .macosNativeFullscreenWindow:
                return
            case nil:
                return
            case .floatingWindow, .macosNativeMinimizedWindow, .tiling,
                 .rootTilingContainer, .shimContainerRelation:
                break
        }

        // Resolve frame; bail if unavailable (window may have closed/minimized
        // before any layout pass).
        guard let nsRect = currentScreenFrame(of: window), nsRect.width > 0, nsRect.height > 0 else {
            return
        }

        let nsColor = parseAARRGGBB(cfg.color) ?? .green
        overlay.flash(
            targetFrame: nsRect,
            color: nsColor,
            width: CGFloat(cfg.width),
            popDistance: CGFloat(cfg.popDistance),
            duration: TimeInterval(cfg.durationMs) / 1000.0,
        )
    }

    // MARK: - Helpers

    /// Convert the window's last-applied layout rect (Airlock's top-left-origin
    /// `Rect`, measured from the top of the main monitor) into an `NSRect` in
    /// NSScreen coordinates (bottom-left origin, Y up). This is the inverse of
    /// `CGRect.monitorFrameNormalized()` in `Rect.swift`.
    ///
    /// We use the sync `lastAppliedLayoutPhysicalRect` rather than the async
    /// `getAxRect()` because the controller runs on `@MainActor` and the
    /// caller is a focus-change callback / hotkey command — both want an
    /// immediate flash without spinning a `Task`. If the window has never
    /// been laid out (e.g. brand-new, not yet bound), we get `nil` and skip
    /// the flash, which is the correct behavior anyway.
    private func currentScreenFrame(of window: Window) -> NSRect? {
        guard let rect = window.lastAppliedLayoutPhysicalRect else { return nil }
        let mainHeight = mainMonitor.height
        return NSRect(
            x: rect.topLeftX,
            y: mainHeight - rect.maxY,
            width: rect.width,
            height: rect.height,
        )
    }
}

func parseAARRGGBB(_ str: String) -> NSColor? {
    var s = str
    if s.hasPrefix("0x") || s.hasPrefix("0X") { s.removeFirst(2) }
    guard s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
    let a = CGFloat((value >> 24) & 0xFF) / 255.0
    let r = CGFloat((value >> 16) & 0xFF) / 255.0
    let g = CGFloat((value >> 8) & 0xFF) / 255.0
    let b = CGFloat(value & 0xFF) / 255.0
    return NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

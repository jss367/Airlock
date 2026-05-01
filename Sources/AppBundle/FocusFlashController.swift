import AppKit
import Common

@MainActor
final class FocusFlashController {
    static let shared = FocusFlashController()

    private lazy var overlay = FocusFlashOverlay()

    /// Tracks the in-flight async AX-rect query so a newer flash can cancel
    /// it. Without this, a slow `getAxRect()` from an earlier focus event
    /// could resolve after a newer flash has already drawn, and overwrite
    /// the newer flash with a stale outline on the wrong window.
    private var pendingAxFlashTask: Task<Void, Never>?

    /// Public entry point — fire a flash on the given window if it's eligible.
    /// Caller is responsible for the `enabled`/`mode` predicate; this method only
    /// handles "is this window flashable?" edge cases.
    func flash(window: Window?) {
        // Any new flash request supersedes a pending async one — even if this
        // call ends up bailing on eligibility, the pending one is now stale.
        pendingAxFlashTask?.cancel()
        pendingAxFlashTask = nil

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

        // Try the sync layout rect first — populated for tiling windows.
        if let nsRect = syncScreenFrame(of: window), nsRect.width > 0, nsRect.height > 0 {
            flashAt(nsRect: nsRect, cfg: cfg)
            return
        }

        // Floating windows have `lastAppliedLayoutPhysicalRect` cleared in
        // `layoutRecursive` and never repopulated, so we have to ask the
        // accessibility API directly. AX queries are async; spin a Task
        // rather than blocking the focus-change callback. The flash will
        // arrive ~10-20ms later than for tiling windows.
        pendingAxFlashTask = Task { @MainActor [weak self] in
            do {
                guard let axRect = try await window.getAxRect() else { return }
                if Task.isCancelled { return }
                guard let self else { return }
                let nsRect = self.airlockRectToNSRect(axRect)
                guard nsRect.width > 0, nsRect.height > 0 else { return }
                self.flashAt(nsRect: nsRect, cfg: cfg)
            } catch {
                // Window vanished or AX call failed — silently no-op.
            }
        }
    }

    private func flashAt(nsRect: NSRect, cfg: FocusFlashSettings) {
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

    /// Sync frame source — populated by `layoutRecursive` for tiling windows
    /// and the workspace itself, but cleared for floating and Airlock-fullscreen
    /// windows. Caller must fall back to async `getAxRect()` when this returns nil.
    private func syncScreenFrame(of window: Window) -> NSRect? {
        guard let rect = window.lastAppliedLayoutPhysicalRect else { return nil }
        return airlockRectToNSRect(rect)
    }

    /// Convert Airlock's top-left-origin `Rect` (measured from the top of the
    /// main monitor) to an `NSRect` in NSScreen coordinates (bottom-left
    /// origin, Y up). Inverse of `CGRect.monitorFrameNormalized()` in `Rect.swift`.
    private func airlockRectToNSRect(_ rect: Rect) -> NSRect {
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

import AppKit

open class NSPanelHud: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow, .utilityWindow],
            backing: .buffered,
            defer: false,
        )
        self.level = .floating
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hidesOnDeactivate = false
        self.isMovableByWindowBackground = false
        self.alphaValue = 1
        self.hasShadow = true
        self.backgroundColor = .clear
    }
}

/// A panel's local key monitor. The panel removes it in `close()`. SwiftUI's `.onDisappear` doesn't
/// fire when the hosting window closes, so a monitor removed there outlives the panel and keeps
/// swallowing keys in every Airlock window
@MainActor
final class PanelKeyMonitor {
    private var monitor: Any?

    func install(_ handler: @escaping (NSEvent) -> Bool) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handler(event) ? nil : event
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

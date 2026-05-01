import AppKit
import QuartzCore

@MainActor
final class FocusFlashOverlay {
    private let panel: NSPanel
    private let outlineLayer: CAShapeLayer

    init() {
        let panel = NSPanel(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false,
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true

        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer = CALayer()
        view.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = view

        let outlineLayer = CAShapeLayer()
        outlineLayer.fillColor = NSColor.clear.cgColor
        outlineLayer.lineJoin = .round
        view.layer?.addSublayer(outlineLayer)

        self.panel = panel
        self.outlineLayer = outlineLayer
    }

    /// Cancel any in-flight animation and start a new pulse on `targetFrame`.
    /// `targetFrame` is in screen coordinates (bottom-left origin, like NSScreen).
    func flash(targetFrame: NSRect, color: NSColor, width: CGFloat, popDistance: CGFloat, duration: TimeInterval) {
        // Order is load-bearing: cancel() must run before the path/opacity
        // reassignments below, so that those reassignments happen outside an
        // active animation transaction and apply instantly without a flicker.
        cancel()

        // Panel must contain both the tight rect and the popped-out rect, so size it
        // to the popped frame plus a few pt of slack for line width.
        let slack = width + 2
        let popped = targetFrame.insetBy(dx: -popDistance, dy: -popDistance)
        let panelFrame = popped.insetBy(dx: -slack, dy: -slack)
        panel.setFrame(panelFrame, display: false)
        panel.contentView?.frame = NSRect(origin: .zero, size: panelFrame.size)
        outlineLayer.frame = panel.contentView?.bounds ?? .zero

        // Initial path: tight outline rect (in panel-local coords).
        let tightLocal = NSRect(
            x: targetFrame.minX - panelFrame.minX,
            y: targetFrame.minY - panelFrame.minY,
            width: targetFrame.width,
            height: targetFrame.height,
        )
        let poppedLocal = tightLocal.insetBy(dx: -popDistance, dy: -popDistance)

        outlineLayer.lineWidth = width
        outlineLayer.strokeColor = color.cgColor
        outlineLayer.path = CGPath(rect: tightLocal, transform: nil)
        outlineLayer.opacity = 1.0

        panel.orderFront(nil)

        // Animate path expansion + opacity fade together.
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setCompletionBlock { [weak self] in
            self?.panel.orderOut(nil)
        }

        let pathAnim = CABasicAnimation(keyPath: "path")
        pathAnim.fromValue = CGPath(rect: tightLocal, transform: nil)
        pathAnim.toValue = CGPath(rect: poppedLocal, transform: nil)
        pathAnim.duration = duration
        pathAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        pathAnim.fillMode = .forwards
        pathAnim.isRemovedOnCompletion = false

        let opacityAnim = CABasicAnimation(keyPath: "opacity")
        opacityAnim.fromValue = 1.0
        opacityAnim.toValue = 0.0
        opacityAnim.duration = duration
        opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)
        opacityAnim.fillMode = .forwards
        opacityAnim.isRemovedOnCompletion = false

        outlineLayer.add(pathAnim, forKey: "pathPop")
        outlineLayer.add(opacityAnim, forKey: "fade")

        CATransaction.commit()
    }

    /// Stop any in-flight animation and hide the panel.
    func cancel() {
        outlineLayer.removeAnimation(forKey: "pathPop")
        outlineLayer.removeAnimation(forKey: "fade")
        outlineLayer.opacity = 0
        panel.orderOut(nil)
    }
}

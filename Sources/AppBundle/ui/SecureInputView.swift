import AppKit
import Carbon
import SwiftUI

private let iconSize = CGSize(width: 50, height: 50)
private let textSize = CGSize(width: 440, height: 170)

private let secureInputSummary = "Secure Input is on, so Airlock's keyboard shortcuts are paused"

public final class SecureInputPanel: NSPanelHud {
    @MainActor public static var shared: SecureInputPanel = SecureInputPanel()
    private var hostingView = NSHostingView(rootView: SecureInputView())

    override private init() {
        super.init()
        // Airlock is rarely the active app, and the collapsed tile explains itself only through its tooltip
        allowsToolTipsWhenApplicationIsInactive = true
    }

    @MainActor
    public func refresh() {
        if let activeMode, sessionCoordinator.isEnabled &&
            config.modes[activeMode].map({ !activeBindings($0.bindings, config).isEmpty }) == true && IsSecureEventInputEnabled()
        {
            if isVisible { return }
            self.contentView?.subviews.removeAll()
            hostingView = NSHostingView(rootView: SecureInputView())
            hostingView.frame = NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height)
            self.contentView?.addSubview(hostingView)
            let x = mainMonitor.width - iconSize.width - 20
            let panelFrame = NSRect(x: x, y: 20, width: iconSize.width, height: iconSize.width)
            self.setFrame(panelFrame, display: true)
            self.orderFrontRegardless()
        } else {
            close()
        }
    }

    public func updateFrame(isMinimized: Bool) {
        let width = isMinimized ? iconSize.width : textSize.width
        let height = isMinimized ? iconSize.height : textSize.height
        hostingView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        let x = mainMonitor.width - width - 20
        let panelFrame = NSRect(x: x, y: 20, width: width, height: height)
        self.setFrame(panelFrame, display: true)
    }
}

struct SecureInputView: View {
    @State var isMinimized: Bool = true

    @Environment(\.colorScheme) var colorScheme: ColorScheme
    private var fontColor: Color {
        colorScheme == .dark ? Color.black : Color.white
    }

    var body: some View {
        ZStack(alignment: .center) {
            Rectangle()
                .fill(Color.gray.opacity(isMinimized ? 0.8 : 1.0))
            if isMinimized {
                Image(systemName: "lock.shield.fill")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(6)
            } else {
                explanation
                    .font(.system(size: 13))
                    .padding(12)
            }
        }
        .foregroundStyle(fontColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
        .frame(
            width: isMinimized ? iconSize.width : textSize.width,
            height: isMinimized ? iconSize.height : textSize.height,
        )
        .help(isMinimized ? "\(secureInputSummary). Click for what to do." : "Click to collapse")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isMinimized ? Text(secureInputSummary) : explanation)
        .accessibilityHint(isMinimized ? "Shows what to do about it" : "Collapses this message")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { toggle() }
    }

    private var explanation: Text {
        Text("""
            **Secure Input is on**, so Airlock can't see your keyboard shortcuts. macOS turns it on while a \
            password field has the keyboard, and some apps leave it on.

            To get shortcuts back, find the app holding it: finish or leave its password prompt, unlock it, \
            or turn off its secure keyboard entry setting (Terminal and iTerm2 have one). Quitting that app \
            releases it too.
            """)
    }

    private func toggle() {
        if !isMinimized {
            SecureInputPanel.shared.refresh()
        }
        isMinimized.toggle()
        SecureInputPanel.shared.updateFrame(isMinimized: isMinimized)
    }
}

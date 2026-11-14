import Common
import SwiftUI

@MainActor
public func getMessageWindow(messageModel: MessageModel) -> some Scene {
    // Using SwiftUI.Window because another class in Airlock is already called Window
    SwiftUI.Window(messageModel.message?.title ?? airlockAppName, id: messageWindowId) {
        MessageView(model: messageModel)
            .onAppear {
                // Set activation policy; otherwise, Airlock windows won't be able to receive focus and accept keyboard input
                NSApp.setActivationPolicy(.accessory)
                NSApplication.shared.windows.forEach {
                    if $0.identifier?.rawValue == messageWindowId {
                        $0.level = .floating
                        $0.styleMask.remove(.miniaturizable) // Disable minimize button, because we don't unminimize the window on config error
                    }
                }
            }
        // .windowMinimizeBehavior(WindowInteractionBehavior.disabled) // SwiftUI way of hiding minimize button. Available only since macOS 15
    }
    .windowResizability(.contentMinSize)
    //.windowLevel(.floating) //This might be the SwiftUI way of doing window level instead of the onAppear block above, but it's only available from macOS 15.0
}

public let messageWindowId = "\(airlockAppName).messageView"

struct MessageView: View {
    @StateObject private var model: MessageModel
    @Environment(\.dismiss) private var dismiss: DismissAction

    init(model: MessageModel) {
        self._model = .init(wrappedValue: model)
    }

    public var body: some View {
        let type = model.message?.type ?? .notice
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: type.symbolName)
                    .font(.system(size: 24))
                    .foregroundStyle(type.tint)
                    .accessibilityLabel(type.accessibilityLabel)
                Text(model.message?.description ?? "")
                    .font(.headline)
                    .textSelection(.enabled)
            }
            // Selectable text can take first responder. The window monitor keeps Return working then.
            ScrollView {
                Text(model.message?.body ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .frame(minHeight: 60, idealHeight: idealBodyHeight)
            .background(Color(.controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            HStack {
                Spacer()
                if type.showsConfigButtons {
                    reloadConfigButton(showShortcutGroup: true)
                    openConfigButton(showShortcutGroup: true)
                }
                let closeButton = Button("Close") { model.message = nil }.keyboardShortcut(.defaultAction)
                shortcutGroup(label: Image(systemName: "return.left"), content: closeButton)
            }
        }
        .padding()
        .frame(minWidth: 480, idealWidth: 560, maxWidth: 960, minHeight: 200)
        .background(MessageCloseKeyMonitor { model.message = nil })
        .onChange(of: model.message) { _, message in
            if message == nil {
                self.dismiss()
            }
        }
        .onDisappear {
            // If user closes the screen with the macOS native close (x) button and then the error is still the same, this window will not appear again
            model.message = nil
        }
    }
}

/// Handle Return before a selectable text view can consume it, scoped to this window only.
private struct MessageCloseKeyMonitor: NSViewRepresentable {
    let close: () -> Void

    func makeNSView(context: Context) -> MessageCloseKeyView { MessageCloseKeyView() }

    func updateNSView(_ view: MessageCloseKeyView, context: Context) { view.onClose = close }

    static func dismantleNSView(_ view: MessageCloseKeyView, coordinator: ()) { view.removeMonitor() }
}

final class MessageCloseKeyView: NSView {
    var onClose: () -> Void = {}
    private let keyMonitor = PanelKeyMonitor()
    private weak var monitoredWindow: NSWindow?
    private var closeObservation: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeMonitor()
        guard let window else { return }
        monitoredWindow = window
        keyMonitor.install { [weak self] event in self?.handle(event) ?? false }
        closeObservation = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeMonitor() }
        }
    }

    func handle(_ event: NSEvent) -> Bool {
        guard let monitoredWindow, event.window === monitoredWindow,
              event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
              event.modifierFlags.isDisjoint(with: [.command, .control, .option, .shift])
        else { return false }
        onClose()
        return true
    }

    func removeMonitor() {
        keyMonitor.remove()
        monitoredWindow = nil
        if let closeObservation { NotificationCenter.default.removeObserver(closeObservation) }
        closeObservation = nil
    }
}

extension MessageView {
    /// Roughly the body's height at the window's ideal width. A long body opens at a size that fits on
    /// screen and scrolls, rather than at its full height
    private var idealBodyHeight: CGFloat {
        let charsPerLine = 64
        let lines = (model.message?.body ?? "").split(separator: "\n", omittingEmptySubsequences: false)
            .map { max(1, ($0.count + charsPerLine - 1) / charsPerLine) }
            .reduce(0, +)
        return CGFloat(min(max(lines, 2), 20)) * 15 + 24
    }
}

public final class MessageModel: ObservableObject {
    @MainActor public static let shared = MessageModel()
    @Published public var message: Message? = nil

    private init() {}
}

public enum MessageType {
    /// The config has a problem. Offers to reload and open it
    case config
    /// Something Airlock tried to do failed
    case runtime
    /// A refusal or an explanation. Nothing is broken
    case notice

    var symbolName: String {
        switch self {
            case .config: "exclamationmark.triangle.fill"
            case .runtime: "xmark.octagon.fill"
            case .notice: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
            case .config: .yellow
            case .runtime: .red
            case .notice: .secondary
        }
    }

    var accessibilityLabel: String {
        switch self {
            case .config: "Warning"
            case .runtime: "Error"
            case .notice: "Note"
        }
    }

    var showsConfigButtons: Bool { self == .config }
}

public struct Message: Hashable, Equatable {
    public let type: MessageType
    public let title: String
    public let description: String
    public let body: String

    init(type: MessageType = .config, title: String = airlockAppName, description: String, body: String) {
        self.type = type
        self.title = title
        self.description = description
        self.body = body
    }
}

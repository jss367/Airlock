import AppKit
import Common
import SwiftUI

final class AppLauncherPanel: NSPanelHud {
    @MainActor static var shared = AppLauncherPanel()
    private let viewModel = AppLauncherViewModel()
    private var eventMonitor: Any?

    private let panelWidth: CGFloat = 500
    private let panelHeight: CGFloat = 400

    override private init() {
        super.init()
        self.styleMask = [.borderless, .hudWindow, .utilityWindow]
        self.level = .floating
        self.isMovableByWindowBackground = false
        self.hasShadow = true
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Debug Logging

    /// Set to `true` to enable verbose NSLog output for diagnosing keyboard/focus issues.
    /// Off by default to avoid leaking keystrokes to the macOS unified log.
    private static var debugLogging: Bool {
        UserDefaults.standard.bool(forKey: "AppLauncherDebug")
    }

    private func logWindowState(_ label: String) {
        guard Self.debugLogging else { return }
        NSLog("[AppLauncher][%@] === Window State ===", label)
        NSLog("[AppLauncher][%@] isKeyWindow=%d isMainWindow=%d canBecomeKey=%d canBecomeMain=%d",
              label, isKeyWindow ? 1 : 0, isMainWindow ? 1 : 0, canBecomeKey ? 1 : 0, canBecomeMain ? 1 : 0)
        NSLog("[AppLauncher][%@] styleMask.rawValue=%lu level.rawValue=%d",
              label, styleMask.rawValue, level.rawValue)
        NSLog("[AppLauncher][%@] isVisible=%d isOnActiveSpace=%d",
              label, isVisible ? 1 : 0, isOnActiveSpace ? 1 : 0)

        // First responder chain
        NSLog("[AppLauncher][%@] === First Responder Chain ===", label)
        if let fr = firstResponder {
            NSLog("[AppLauncher][%@] firstResponder: %@ (%@)", label, String(describing: fr), String(describing: type(of: fr)))
            var responder: NSResponder? = fr.nextResponder
            var depth = 1
            while let r = responder {
                NSLog("[AppLauncher][%@] chain[%d]: %@ (%@)", label, depth, String(describing: r), String(describing: type(of: r)))
                responder = r.nextResponder
                depth += 1
                if depth > 20 { break }
            }
        } else {
            NSLog("[AppLauncher][%@] firstResponder: nil", label)
        }

        // NSApp state
        NSLog("[AppLauncher][%@] === NSApp State ===", label)
        NSLog("[AppLauncher][%@] NSApp.isActive=%d", label, NSApp.isActive ? 1 : 0)
        if let kw = NSApp.keyWindow {
            NSLog("[AppLauncher][%@] NSApp.keyWindow: %@ (isSelf=%d)", label, String(describing: type(of: kw)), kw === self ? 1 : 0)
        } else {
            NSLog("[AppLauncher][%@] NSApp.keyWindow: nil", label)
        }
        if let mw = NSApp.mainWindow {
            NSLog("[AppLauncher][%@] NSApp.mainWindow: %@ (isSelf=%d)", label, String(describing: type(of: mw)), mw === self ? 1 : 0)
        } else {
            NSLog("[AppLauncher][%@] NSApp.mainWindow: nil", label)
        }

        // Content view hierarchy
        NSLog("[AppLauncher][%@] === Content View ===", label)
        if let cv = contentView {
            NSLog("[AppLauncher][%@] contentView: %@ (%@)", label, String(describing: cv), String(describing: type(of: cv)))
            logSubviews(cv, label: label, depth: 1)
        } else {
            NSLog("[AppLauncher][%@] contentView: nil", label)
        }
    }

    private func logSubviews(_ view: NSView, label: String, depth: Int) {
        guard Self.debugLogging else { return }
        for (i, subview) in view.subviews.enumerated() {
            let indent = String(repeating: "  ", count: depth)
            NSLog("[AppLauncher][%@] %@subview[%d]: %@ frame=%@", label, indent, i,
                  String(describing: type(of: subview)), NSStringFromRect(subview.frame))
            if depth < 5 {
                logSubviews(subview, label: label, depth: depth + 1)
            }
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if Self.debugLogging, event.type == .keyDown {
            NSLog("[AppLauncher][sendEvent] keyDown keyCode=%d chars='%@' charsIgnoringMods='%@' firstResponder=%@",
                  event.keyCode,
                  event.characters ?? "<nil>",
                  event.charactersIgnoringModifiers ?? "<nil>",
                  String(describing: firstResponder.map { type(of: $0) }))
        }
        super.sendEvent(event)
    }

    override func keyDown(with event: NSEvent) {
        if Self.debugLogging {
            NSLog("[AppLauncher][keyDown] PANEL received keyDown keyCode=%d chars='%@' — this means no responder handled it",
                  event.keyCode, event.characters ?? "<nil>")
        }
        super.keyDown(with: event)
    }

    override func becomeKey() {
        if Self.debugLogging { NSLog("[AppLauncher][becomeKey] Panel becoming key window") }
        super.becomeKey()
    }

    override func resignKey() {
        if Self.debugLogging { NSLog("[AppLauncher][resignKey] Panel resigning key window") }
        super.resignKey()
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let result = super.makeFirstResponder(responder)
        if Self.debugLogging {
            NSLog("[AppLauncher][makeFirstResponder] responder=%@ (%@) result=%d",
                  String(describing: responder),
                  String(describing: responder.map { type(of: $0) }),
                  result ? 1 : 0)
        }
        return result
    }

    @MainActor
    func show() {
        if Self.debugLogging { NSLog("[AppLauncher] === show() called ===") }

        viewModel.reset()

        let hostingView = NSHostingView(rootView: AppLauncherView(viewModel: viewModel, panel: self))
        self.contentView = hostingView

        let monitor = mainMonitor
        let x = monitor.rect.minX + (monitor.width - panelWidth) / 2
        let y = monitor.rect.minY + (monitor.height - panelHeight) / 2
        self.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)

        if Self.debugLogging { NSLog("[AppLauncher] Before makeKeyAndOrderFront — isKeyWindow=%d", isKeyWindow ? 1 : 0) }
        self.makeKeyAndOrderFront(nil)
        if Self.debugLogging { NSLog("[AppLauncher] After makeKeyAndOrderFront — isKeyWindow=%d", isKeyWindow ? 1 : 0) }

        NSApp.activate(ignoringOtherApps: true)
        if Self.debugLogging { NSLog("[AppLauncher] After NSApp.activate — NSApp.isActive=%d", NSApp.isActive ? 1 : 0) }

        logWindowState("show-immediate")

        // Log again after a delay to capture state once the window is fully presented
        if Self.debugLogging {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.logWindowState("show-delayed-0.5s")
            }
        }

        removeEventMonitor()
        installEventMonitor()
    }

    @MainActor
    func dismiss() {
        removeEventMonitor()
        self.orderOut(nil)
        // Restore focus to the previously focused window
        focus.windowOrNil?.nativeFocus()
    }

    @MainActor
    func launchApp(_ app: InstalledApp) {
        dismiss()

        // Check if the app is already running and has windows
        let runningApp: MacApp? = app.bundleIdentifier.flatMap { bundleId in
            MacApp.allAppsMap.values.first { $0.rawAppBundleId == bundleId }
        }

        if let runningApp {
            // App is running — find its windows
            let appWindows = Workspace.all
                .flatMap { ws in ws.allLeafWindowsRecursive.filter { $0.app.pid == runningApp.pid } }

            let currentWorkspace = focus.workspace
            let windowOnCurrentWs = appWindows.first { $0.nodeWorkspace == currentWorkspace }

            if let windowOnCurrentWs {
                // Already on current workspace — just focus it
                windowOnCurrentWs.nativeFocus()
            } else if let windowToMove = appWindows.first {
                // Move a window from another workspace to current
                _ = windowToMove.bindAsFloatingWindow(to: currentWorkspace)
                windowToMove.nativeFocus()
            } else {
                // Running but no windows — launch a new instance
                launchViaWorkspace(app)
            }
        } else {
            launchViaWorkspace(app)
        }
    }

    private func launchViaWorkspace(_ app: InstalledApp) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: app.url, configuration: config)
    }

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                if AppLauncherPanel.debugLogging {
                    NSLog("[AppLauncher][eventMonitor] self is nil, passing event through keyCode=%d", event.keyCode)
                }
                return event
            }
            if Self.debugLogging {
                NSLog("[AppLauncher][eventMonitor] keyDown keyCode=%d chars='%@' charsIgnoringMods='%@'",
                      event.keyCode, event.characters ?? "<nil>", event.charactersIgnoringModifiers ?? "<nil>")
            }
            switch event.keyCode {
            case 53: // Escape
                if Self.debugLogging { NSLog("[AppLauncher][eventMonitor] Escape — consuming event, will dismiss") }
                MainActor.assumeIsolated { self.dismiss() }
                return nil
            case 36: // Return
                if Self.debugLogging { NSLog("[AppLauncher][eventMonitor] Return — consuming event, will launch") }
                MainActor.assumeIsolated {
                    if let app = self.viewModel.selectedApp {
                        self.launchApp(app)
                    }
                }
                return nil
            case 125: // Down arrow
                if Self.debugLogging { NSLog("[AppLauncher][eventMonitor] Down arrow — consuming event") }
                MainActor.assumeIsolated { self.viewModel.selectNext() }
                return nil
            case 126: // Up arrow
                if Self.debugLogging { NSLog("[AppLauncher][eventMonitor] Up arrow — consuming event") }
                MainActor.assumeIsolated { self.viewModel.selectPrevious() }
                return nil
            default:
                if Self.debugLogging { NSLog("[AppLauncher][eventMonitor] keyCode=%d — passing event through (NOT consumed)", event.keyCode) }
                return event
            }
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }
}

@MainActor
final class AppLauncherViewModel: ObservableObject {
    @Published var searchText = ""
    @Published var selectedIndex = 0
    private var allApps: [InstalledApp] = []

    var filteredApps: [InstalledApp] {
        if searchText.isEmpty { return allApps }
        return allApps
            .compactMap { app -> (InstalledApp, Int)? in
                guard let score = fuzzyMatch(query: searchText, target: app.name) else { return nil }
                return (app, score)
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var selectedApp: InstalledApp? {
        let apps = filteredApps
        guard selectedIndex >= 0 && selectedIndex < apps.count else { return nil }
        return apps[selectedIndex]
    }

    func reset() {
        searchText = ""
        selectedIndex = 0
        allApps = discoverInstalledApps()
    }

    func selectNext() {
        let count = filteredApps.count
        if selectedIndex < count - 1 {
            selectedIndex += 1
        }
    }

    func selectPrevious() {
        if selectedIndex > 0 {
            selectedIndex -= 1
        }
    }
}

struct AppLauncherView: View {
    @ObservedObject var viewModel: AppLauncherViewModel
    let panel: AppLauncherPanel

    @Environment(\.colorScheme) var colorScheme
    @FocusState private var isFocused: Bool

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: .init(white: 0.15, alpha: 0.95))
            : Color(nsColor: .init(white: 0.95, alpha: 0.95))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 18))
                TextField("Search apps...", text: $viewModel.searchText)
                    .focused($isFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .onSubmit {
                        if let app = viewModel.selectedApp {
                            panel.launchApp(app)
                        }
                    }
                    .onChange(of: viewModel.searchText) { _ in
                        viewModel.selectedIndex = 0
                    }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Results list
            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(viewModel.filteredApps.enumerated()), id: \.offset) { index, app in
                            AppRow(app: app, isSelected: index == viewModel.selectedIndex)
                                .id(index)
                                .onTapGesture {
                                    viewModel.selectedIndex = index
                                    panel.launchApp(app)
                                }
                        }
                    }
                }
                .onChange(of: viewModel.selectedIndex) { newIndex in
                    withAnimation {
                        scrollProxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .background(backgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onAppear { isFocused = true }
    }
}

struct AppRow: View {
    let app: InstalledApp
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 32, height: 32)
            Text(app.name)
                .font(.system(size: 16))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.3) : Color.clear)
        .contentShape(Rectangle())
    }
}

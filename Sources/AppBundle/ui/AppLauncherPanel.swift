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

    @MainActor
    func show() {
        viewModel.reset()

        let hostingView = NSHostingView(rootView: AppLauncherView(viewModel: viewModel, panel: self))
        self.contentView = hostingView

        let monitor = mainMonitor
        let x = monitor.rect.minX + (monitor.width - panelWidth) / 2
        let y = monitor.rect.minY + (monitor.height - panelHeight) / 2
        self.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)

        self.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
            guard let self else { return event }
            switch event.keyCode {
            case 53: // Escape
                MainActor.assumeIsolated { self.dismiss() }
                return nil
            case 36: // Return
                MainActor.assumeIsolated {
                    if let app = self.viewModel.selectedApp {
                        self.launchApp(app)
                    }
                }
                return nil
            case 125: // Down arrow
                MainActor.assumeIsolated { self.viewModel.selectNext() }
                return nil
            case 126: // Up arrow
                MainActor.assumeIsolated { self.viewModel.selectPrevious() }
                return nil
            default:
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

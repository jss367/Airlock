import AppKit
import Common
import SwiftUI

@MainActor
func showAboutWindow() {
    AboutWindowController.shared.present()
}

final class AboutWindowController: NSWindowController {
    @MainActor static let shared = AboutWindowController(window: makeWindow())

    @MainActor static func makeWindow() -> NSWindow {
        let window = AgentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
        )
        window.title = "About \(airlockAppName)"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AboutContent())
        window.center()
        return window
    }

    @MainActor func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AboutContent: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            VStack(spacing: 4) {
                Text(airlockAppName)
                    .font(.title.bold())
                Text("Version \(airlockAppVersion) (\(gitShortHash))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button("Copy Version") {
                "\(airlockAppName) v\(airlockAppVersion) \(gitHash)".copyToClipboard()
            }
            Divider()
            VStack(spacing: 10) {
                CheckForUpdatesButton()
                Button("Welcome to \(airlockAppName)…") {
                    showWelcomeWindow()
                }
            }
        }
        .padding(24)
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

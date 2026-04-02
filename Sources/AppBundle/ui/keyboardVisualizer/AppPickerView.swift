import AppKit
import SwiftUI

struct AppPickerView: View {
    let keyNotation: String
    let modifierPrefix: NSEvent.ModifierFlags
    let onDismiss: () -> Void

    @State private var searchText = ""
    @State private var allApps: [InstalledApp] = []
    @State private var errorMessage: String?

    private var filteredApps: [InstalledApp] {
        if searchText.isEmpty { return allApps }
        let query = searchText.lowercased()
        return allApps.filter { $0.name.lowercased().contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Bind \(modifierPrefix.toString())-\(keyNotation)")
                    .font(.headline)
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search apps...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // App list
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredApps, id: \.url) { app in
                        AppPickerRow(app: app)
                            .contentShape(Rectangle())
                            .onTapGesture { selectApp(app) }
                    }
                }
            }

            // Error display
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 400, height: 500)
        .onAppear { loadApps() }
    }

    @MainActor
    private func loadApps() {
        allApps = discoverInstalledApps()
    }

    private func selectApp(_ app: InstalledApp) {
        do {
            try addBinding(key: keyNotation, appName: app.name, modifierPrefix: modifierPrefix)
            Task { @MainActor in
                _ = try? await reloadConfig()
                onDismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct AppPickerRow: View {
    let app: InstalledApp

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 32, height: 32)
            Text(app.name)
                .font(.system(size: 14))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.clear)
    }
}

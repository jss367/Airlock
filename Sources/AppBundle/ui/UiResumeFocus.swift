import AppKit
import Common

/// Remembers the last external app without changing Airlock's focus while paused. Query its
/// current window on resume, since the user may have changed windows before opening Settings.
@MainActor
final class UiResumeFocusState {
    private var externalFocusQuery: (@MainActor () async throws -> Window?)?
    private var generation = 0

    func remember(_ query: @MainActor @escaping () async throws -> Window?) {
        externalFocusQuery = query
        generation += 1
    }

    func reset() {
        externalFocusQuery = nil
        generation += 1
    }

    func windowToResume(nativeFocus: @MainActor () async throws -> Window?) async throws -> Window? {
        if let native = try await nativeFocus() { return native.isBound ? native : nil }
        while let query = externalFocusQuery {
            let version = generation
            let remembered = try await query()
            // The user can leave Settings while the AX query is suspended. Prefer that newer focus.
            if let native = try await nativeFocus() { return native.isBound ? native : nil }
            // Or visit another app and return to Settings. Don't apply the older app's answer.
            if version != generation { continue }
            return remembered?.isBound == true ? remembered : nil
        }
        return nil
    }
}

@MainActor let uiResumeFocus = UiResumeFocusState()

@MainActor
func rememberExternalAppForUiResume(_ app: NSRunningApplication?) {
    guard let app, app.processIdentifier != myPid, app.bundleIdentifier != lockScreenAppBundleId else { return }
    uiResumeFocus.remember { try await MacApp.getOrRegister(app)?.getFocusedWindow() }
}

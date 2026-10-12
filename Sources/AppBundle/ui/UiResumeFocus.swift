import AppKit
import Common

enum UiResumeFocusError: LocalizedError {
    case focusKeptChanging

    var errorDescription: String? {
        "Focus kept changing while Airlock was resuming. Try Resume again."
    }
}

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
        // If focus keeps changing, abort the resume rather than enable with the stale paused model.
        for _ in 0 ..< 3 {
            let version = generation
            let native = try await nativeFocus()
            if version != generation { continue }
            if let native { return native.isBound ? native : nil }
            guard let query = externalFocusQuery else { return nil }
            let remembered = try await query()
            if version != generation { continue }
            // The user can leave Settings while the AX query is suspended. Prefer that newer focus.
            let currentNative = try await nativeFocus()
            // Or activate another app while either query is suspended. Reject even nonnil stale answers.
            if version != generation { continue }
            if let currentNative { return currentNative.isBound ? currentNative : nil }
            return remembered?.isBound == true ? remembered : nil
        }
        throw UiResumeFocusError.focusKeptChanging
    }
}

@MainActor let uiResumeFocus = UiResumeFocusState()

@MainActor
func rememberExternalAppForUiResume(_ app: NSRunningApplication?) {
    guard let app, app.processIdentifier != myPid, app.bundleIdentifier != lockScreenAppBundleId else { return }
    uiResumeFocus.remember { try await MacApp.getOrRegister(app)?.getFocusedWindow() }
}

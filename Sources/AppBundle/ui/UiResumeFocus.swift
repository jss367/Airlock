import AppKit
import Common

enum UiResumeFocusError: LocalizedError {
    case focusKeptChanging
    case selectedWindowUnavailable

    var errorDescription: String? {
        switch self {
            case .focusKeptChanging: "Focus kept changing while Airlock was resuming. Try Resume again."
            case .selectedWindowUnavailable: "The selected window is no longer available. Try Resume again."
        }
    }
}

/// Queries identify a candidate without registering apps/windows or running detection callbacks.
/// The selected candidate is resolved once, in the committed resume path.
@MainActor
struct UiResumeFocusCandidate {
    private let isAvailable: () -> Bool
    private let resolve: () async throws -> Window?

    init(_ window: Window) {
        isAvailable = { window.isBound }
        resolve = { window.isBound ? window : nil }
    }

    init(isAvailable: @escaping () -> Bool = { true }, resolve: @escaping () async throws -> Window?) {
        self.isAvailable = isAvailable
        self.resolve = resolve
    }

    var available: Bool { isAvailable() }
    func resolveAfterSelection() async throws -> Window? { try await resolve() }
}

/// Remembers the last external app without changing Airlock's focus while paused. Query its
/// current window on resume, since the user may have changed windows before opening Settings.
@MainActor
final class UiResumeFocusState {
    private var externalFocusQuery: (@MainActor () async throws -> UiResumeFocusCandidate?)?
    private var generation = 0

    func remember(_ query: @MainActor @escaping () async throws -> Window?) {
        rememberCandidate { try await query().map(UiResumeFocusCandidate.init) }
    }

    func rememberCandidate(_ query: @MainActor @escaping () async throws -> UiResumeFocusCandidate?) {
        externalFocusQuery = query
        generation += 1
    }

    func reset() {
        externalFocusQuery = nil
        generation += 1
    }

    func windowToResume(nativeFocus: @MainActor () async throws -> Window?) async throws -> Window? {
        let candidate = try await candidateToResume(nativeFocus: {
            try await nativeFocus().map(UiResumeFocusCandidate.init)
        })
        return try await candidate?.resolveAfterSelection()
    }

    func candidateToResume(nativeFocus: @MainActor () async throws -> UiResumeFocusCandidate?) async throws -> UiResumeFocusCandidate? {
        // If focus keeps changing, abort the resume rather than enable with the stale paused model.
        for _ in 0 ..< 3 {
            let version = generation
            let native = try await nativeFocus()
            if version != generation { continue }
            if let native { return native.available ? native : nil }
            guard let query = externalFocusQuery else { return nil }
            let remembered = try await query()
            if version != generation { continue }
            // The user can leave Settings while the AX query is suspended. Prefer that newer focus.
            let currentNative = try await nativeFocus()
            // Or activate another app while either query is suspended. Reject even nonnil stale answers.
            if version != generation { continue }
            if let currentNative { return currentNative.available ? currentNative : nil }
            return remembered?.available == true ? remembered : nil
        }
        throw UiResumeFocusError.focusKeptChanging
    }
}

@MainActor let uiResumeFocus = UiResumeFocusState()

@MainActor
func rememberExternalAppForUiResume(_ app: NSRunningApplication?) {
    guard let app, app.processIdentifier != myPid, app.bundleIdentifier != lockScreenAppBundleId else { return }
    uiResumeFocus.rememberCandidate { await focusCandidateForUiResume(app) }
}

@MainActor
func nativeFocusCandidateForUiResume() async throws -> UiResumeFocusCandidate? {
    if isUnitTest { return try await appForTests?.getFocusedWindow().map(UiResumeFocusCandidate.init) }
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return await focusCandidateForUiResume(app)
}

@MainActor
private func focusCandidateForUiResume(_ app: NSRunningApplication) async -> UiResumeFocusCandidate? {
    let pid = app.processIdentifier
    guard pid != myPid, app.bundleIdentifier != lockScreenAppBundleId, !app.isTerminated else { return nil }
    let debugId = app.idForDebug
    // One read-only AX query. No observers, model binding, window-detection callbacks, or app activation.
    let windowId = await Task.detached {
        $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: pid, idForDebug: debugId)) {
            AXUIElementCreateApplication(pid).get(Ax.focusedWindowAttr)?.windowId
        }
    }.value
    guard let windowId else { return nil }
    return UiResumeFocusCandidate(isAvailable: { !app.isTerminated }) {
        guard let macApp = try await MacApp.getOrRegister(app) else { return nil }
        return try await MacWindow.getOrRegister(windowId: windowId, macApp: macApp)
    }
}

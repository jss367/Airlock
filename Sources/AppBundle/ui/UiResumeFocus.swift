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
    private let isStillFocused: () async throws -> Bool
    private let resolve: (@MainActor () throws -> Void) async throws -> Window?
    private var resolveWithAdmission: ((@MainActor () throws -> Void, @MainActor () async throws -> Void) async throws -> Window?)?
    private var selectionIsCurrent: @MainActor () -> Bool = { true }

    init(_ window: Window) {
        isAvailable = { window.isBound }
        isStillFocused = { true }
        resolve = { validate in
            try validate()
            return window.isBound ? window : nil
        }
    }

    init(isAvailable: @escaping () -> Bool = { true }, isStillFocused: @escaping () async throws -> Bool = { true }, resolve: @escaping () async throws -> Window?) {
        self.isAvailable = isAvailable
        self.isStillFocused = isStillFocused
        self.resolve = { validate in
            try validate()
            return try await resolve()
        }
    }

    init(isAvailable: @escaping () -> Bool = { true }, isStillFocused: @escaping () async throws -> Bool = { true }, resolveValidated: @escaping (@MainActor () throws -> Void) async throws -> Window?) {
        self.isAvailable = isAvailable
        self.isStillFocused = isStillFocused
        resolve = resolveValidated
    }

    init(isAvailable: @escaping () -> Bool = { true }, isStillFocused: @escaping () async throws -> Bool, resolveWithAdmission: @escaping (@MainActor () throws -> Void, @MainActor () async throws -> Void) async throws -> Window?) {
        self.isAvailable = isAvailable
        self.isStillFocused = isStillFocused
        self.resolve = { _ in nil }
        self.resolveWithAdmission = resolveWithAdmission
    }

    var available: Bool { isAvailable() }
    func selected(whileCurrent check: @MainActor @escaping () -> Bool) -> Self {
        var selected = self
        selected.selectionIsCurrent = check
        return selected
    }

    func validateAfterSelection(validateIntent: @MainActor @escaping () throws -> Void = {}) async throws {
        try validateIntent()
        guard selectionIsCurrent() else { throw UiResumeFocusError.focusKeptChanging }
        guard isAvailable() else { throw UiResumeFocusError.selectedWindowUnavailable }
        guard try await isStillFocused() else { throw UiResumeFocusError.focusKeptChanging }
        try validateIntent()
        guard selectionIsCurrent() else { throw UiResumeFocusError.focusKeptChanging }
        guard isAvailable() else { throw UiResumeFocusError.selectedWindowUnavailable }
    }

    func resolveAfterSelection(validateIntent: @MainActor @escaping () throws -> Void = {}) async throws -> Window? {
        let validate: @MainActor () throws -> Void = {
            try validateIntent()
            guard selectionIsCurrent() else { throw UiResumeFocusError.focusKeptChanging }
        }
        try validate()
        let admit: @MainActor () async throws -> Void = {
            try validate()
            guard try await isStillFocused() else { throw UiResumeFocusError.focusKeptChanging }
            try validate()
        }
        let window: Window? = if let resolveWithAdmission { try await resolveWithAdmission(validate, admit) }
        else { try await resolve(validate) }
        try validate()
        // A same-app window change has no application-activation generation. Read its identity again.
        guard try await isStillFocused() else { throw UiResumeFocusError.focusKeptChanging }
        try validate()
        return window
    }
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
            if let native { return native.available ? native.selected { self.generation == version } : nil }
            guard let query = externalFocusQuery else { return nil }
            let remembered = try await query()
            if version != generation { continue }
            // The user can leave Settings while the AX query is suspended. Prefer that newer focus.
            let currentNative = try await nativeFocus()
            // Or activate another app while either query is suspended. Reject even nonnil stale answers.
            if version != generation { continue }
            if let currentNative { return currentNative.available ? currentNative.selected { self.generation == version } : nil }
            return remembered?.available == true ? remembered?.selected { self.generation == version } : nil
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
    let windowId = await readOnlyFocusedWindowIdForUiResume(pid: pid, debugId: debugId)
    guard let windowId else { return nil }
    return UiResumeFocusCandidate(
        isAvailable: { !app.isTerminated },
        isStillFocused: {
            guard !app.isTerminated else { return false }
            let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard before == pid || before == myPid else { return false }
            let currentId = await readOnlyFocusedWindowIdForUiResume(pid: pid, debugId: debugId)
            let after = NSWorkspace.shared.frontmostApplication?.processIdentifier
            return currentId == windowId && (after == pid || after == myPid)
        },
        resolveWithAdmission: { validate, admit in
            guard let macApp = try await MacApp.getOrRegister(app) else { return nil }
            try validate()
            return try await macApp.getFocusedWindow(expectedWindowId: windowId, beforeRegistration: validate, beforeDetectionCallbacks: admit)
        },
    )
}

private func readOnlyFocusedWindowIdForUiResume(pid: Int32, debugId: String) async -> UInt32? {
    await Task.detached {
        $axTaskLocalAppThreadToken.withValue(AxAppThreadToken(pid: pid, idForDebug: debugId)) {
            AXUIElementCreateApplication(pid).get(Ax.focusedWindowAttr)?.windowId
        }
    }.value
}

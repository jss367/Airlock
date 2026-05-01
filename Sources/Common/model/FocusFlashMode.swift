public enum FocusFlashMode: String, Equatable, Sendable, CaseIterable {
    case every = "every"
    case crossWorkspace = "cross-workspace"
    case crossApp = "cross-app"
    case idle = "idle"
    case off = "off"
}

import Common
import Foundation
import os

private let errorLogger = Logger(subsystem: airlockAppId, category: "errors")

/// Cancellation is normal when a newer window event replaces an in-flight task.
/// Keep the error domain and code even when the localized description is generic.
struct AppErrorReport {
    let operation: String
    let domain: String
    let code: Int
    let details: String

    init?(_ error: any Error, operation: String) {
        guard !(error is CancellationError) else { return nil }
        let nsError = error as NSError
        self.operation = operation
        self.domain = nsError.domain
        self.code = nsError.code
        self.details = "\(nsError.localizedDescription) (\(nsError.domain), code \(nsError.code))"
    }
}

@discardableResult
func logAppError(_ error: any Error, operation: String) -> AppErrorReport? {
    guard let report = AppErrorReport(error, operation: operation) else { return nil }
    // Error descriptions can contain paths and window titles. Keep those private in unified logs.
    errorLogger.error("\(report.operation, privacy: .public) failed (\(report.domain, privacy: .public), code \(report.code)): \(report.details, privacy: .private)")
    return report
}

@MainActor
func reportAppError(_ error: any Error, operation: String, userMessage: String? = nil) {
    guard let report = logAppError(error, operation: operation), let userMessage else { return }
    MessageModel.shared.message = Message(
        type: .runtime,
        description: userMessage,
        body: "\(report.operation)\n\n\(report.details)",
    )
}

/// Use at fire-and-forget task boundaries, where there is no caller to receive a thrown error.
/// Background work logs only; explicit user actions can also explain the failure in the UI.
@MainActor
@discardableResult
func withErrorReporting(
    _ operation: String,
    userMessage: String? = nil,
    body: () async throws -> Void,
) async -> Bool {
    do {
        try await body()
        return true
    } catch {
        reportAppError(error, operation: operation, userMessage: userMessage)
        return false
    }
}

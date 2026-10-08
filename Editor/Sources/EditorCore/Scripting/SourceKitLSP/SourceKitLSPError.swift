import Foundation

/// Failures raised while talking to a `sourcekit-lsp` process.
///
/// Kept free of UI wording so both the editor surface and headless tooling
/// can present the same diagnostics.
public enum SourceKitLSPClientError: Error, LocalizedError, Sendable, Equatable {
    case executableNotFound(String)
    case launchFailed(String)
    case protocolViolation(String)
    case serverError(code: Int, message: String)
    case requestTimedOut(String)
    case processTerminated(Int32)
    case connectionClosed
    case notRunning

    public var errorDescription: String? {
        switch self {
        case let .executableNotFound(path):
            return "Could not locate sourcekit-lsp at '\(path)'. Set GUAVA_SOURCEKIT_LSP_PATH to the toolchain executable."
        case let .launchFailed(message):
            return "Could not start sourcekit-lsp: \(message)"
        case let .protocolViolation(message):
            return "Invalid SourceKit-LSP message: \(message)"
        case let .serverError(code, message):
            return "SourceKit-LSP request failed (\(code)): \(message)"
        case let .requestTimedOut(method):
            return "SourceKit-LSP request '\(method)' timed out."
        case let .processTerminated(status):
            return "sourcekit-lsp exited with status \(status)."
        case .connectionClosed:
            return "SourceKit-LSP closed its connection."
        case .notRunning:
            return "SourceKit-LSP is not running."
        }
    }
}

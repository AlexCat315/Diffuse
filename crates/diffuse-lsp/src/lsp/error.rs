//! `LSPClientError` — failures raised while talking to a language-server process.
//!
//! Kept free of UI wording so both the editor surface and headless tooling can
//! present the same diagnostics.

use thiserror::Error;

#[derive(Clone, Debug, PartialEq, Eq, Error)]
pub enum LspClientError {
    #[error("Could not locate sourcekit-lsp at '{0}'. Set COVE_SOURCEKIT_LSP_PATH to the toolchain executable.")]
    ExecutableNotFound(String),
    #[error("Could not start sourcekit-lsp: {0}")]
    LaunchFailed(String),
    #[error("Invalid SourceKit-LSP message: {0}")]
    ProtocolViolation(String),
    #[error("SourceKit-LSP request failed ({code}): {message}")]
    ServerError { code: i64, message: String },
    #[error("SourceKit-LSP request '{0}' timed out.")]
    RequestTimedOut(String),
    #[error("sourcekit-lsp exited with status {0}.")]
    ProcessTerminated(i32),
    #[error("SourceKit-LSP closed its connection.")]
    ConnectionClosed,
    #[error("SourceKit-LSP is not running.")]
    NotRunning,
}

/// A failure paired with the stderr tail observed at the time.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LspFailure {
    pub error: LspClientError,
    pub stderr: String,
}

impl LspFailure {
    /// Swift trimmed the stderr tail when constructing the failure.
    pub fn new(error: LspClientError, stderr: impl Into<String>) -> Self {
        LspFailure { error, stderr: stderr.into().trim().to_string() }
    }

    /// Swift's `message`: the reason, then the trimmed stderr on its own line.
    pub fn message(&self) -> String {
        let reason = self.error.to_string();
        if self.stderr.is_empty() { reason } else { format!("{reason}\n{}", self.stderr) }
    }
}

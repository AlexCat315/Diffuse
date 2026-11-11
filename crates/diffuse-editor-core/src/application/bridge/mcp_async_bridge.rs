//! `Editor/Sources/EditorCore/Application/Bridge/MCPAsyncBridge.swift`.
//!
//! The editor bridge is intentionally synchronous on its local TCP boundary.
//! Swift awaited a small actor operation behind a semaphore; Rust has no async
//! runtime, so the operation runs on a scoped worker thread and the caller waits
//! with the same timeout and the same two failure modes.

use std::sync::mpsc;
use std::time::Duration;

#[derive(Debug, thiserror::Error)]
pub enum McpAsyncBridgeError {
    #[error("asynchronous editor operation timed out")]
    TimedOut,
    #[error("asynchronous editor operation returned no result")]
    MissingResult,
    #[error(transparent)]
    Operation(Box<dyn std::error::Error + Send + Sync>),
}

impl McpAsyncBridgeError {
    /// Swift's `CustomStringConvertible.description`.
    pub fn description(&self) -> String {
        self.to_string()
    }
}

/// Swift's default `timeout: TimeInterval = 5`.
pub const DEFAULT_MCP_CAPABILITY_TIMEOUT: Duration = Duration::from_secs(5);

/// Runs `operation` and waits up to `timeout` for its result.
pub fn wait_for_mcp_capability_result<Value, Failure>(
    timeout: Duration,
    operation: impl FnOnce() -> Result<Value, Failure> + Send + 'static,
) -> Result<Value, McpAsyncBridgeError>
where
    Value: Send + 'static,
    Failure: std::error::Error + Send + Sync + 'static,
{
    let (sender, receiver) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = sender.send(operation());
    });
    match receiver.recv_timeout(timeout) {
        Ok(Ok(value)) => Ok(value),
        Ok(Err(error)) => Err(McpAsyncBridgeError::Operation(Box::new(error))),
        Err(mpsc::RecvTimeoutError::Timeout) => Err(McpAsyncBridgeError::TimedOut),
        Err(mpsc::RecvTimeoutError::Disconnected) => Err(McpAsyncBridgeError::MissingResult),
    }
}

/// The all-default form of [`wait_for_mcp_capability_result`].
pub fn wait_for_mcp_capability_result_default<Value, Failure>(
    operation: impl FnOnce() -> Result<Value, Failure> + Send + 'static,
) -> Result<Value, McpAsyncBridgeError>
where
    Value: Send + 'static,
    Failure: std::error::Error + Send + Sync + 'static,
{
    wait_for_mcp_capability_result(DEFAULT_MCP_CAPABILITY_TIMEOUT, operation)
}

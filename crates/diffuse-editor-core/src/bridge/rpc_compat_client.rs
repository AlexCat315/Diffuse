//! Translation of Editor/Sources/EditorCore/Bridge/RpcCompatClient.swift.
//!
//! The pre-MCP RPC surface: a transport-agnostic method call with string
//! payloads. Swift models it with `async throws`; there is no async runtime in
//! Rust, so the call is synchronous and errors travel in the `Result`.

use std::collections::BTreeMap;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RpcResponse {
    pub payload: BTreeMap<String, String>,
}

impl RpcResponse {
    pub fn new(payload: BTreeMap<String, String>) -> Self {
        RpcResponse { payload }
    }
}

pub trait RpcCompatClient: Send + Sync {
    fn call(
        &self,
        method: &str,
        params: &BTreeMap<String, String>,
    ) -> Result<RpcResponse, RpcCompatError>;
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum RpcCompatError {
    #[error("RPC method is not implemented")]
    NotImplemented,
}

#[derive(Clone, Copy, Debug, Default)]
pub struct StubRpcCompatClient;

impl StubRpcCompatClient {
    pub fn new() -> Self {
        StubRpcCompatClient
    }
}

impl RpcCompatClient for StubRpcCompatClient {
    fn call(
        &self,
        method: &str,
        _params: &BTreeMap<String, String>,
    ) -> Result<RpcResponse, RpcCompatError> {
        match method {
            "editor.ping" => {
                let mut payload = BTreeMap::new();
                payload.insert("ok".to_string(), "true".to_string());
                Ok(RpcResponse::new(payload))
            }
            "editor.getCapabilities" => {
                let mut payload = BTreeMap::new();
                payload.insert("version".to_string(), "stub-v1".to_string());
                Ok(RpcResponse::new(payload))
            }
            _ => Err(RpcCompatError::NotImplemented),
        }
    }
}

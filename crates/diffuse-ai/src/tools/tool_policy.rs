//! Ported from `Engine/Sources/AIRuntime/Tools/ToolPolicy.swift`.

use std::sync::Arc;

use diffuse_plugin::base64_data::Data;

/// One model-facing tool invocation observed before it executes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolCall {
    pub name: String,
    /// Canonical JSON arguments; empty when the tool takes none.
    pub arguments: Data,
    pub origin: ToolCallOrigin,
}

impl ToolCall {
    pub fn new(name: impl Into<String>, arguments: Data, origin: ToolCallOrigin) -> Self {
        Self {
            name: name.into(),
            arguments,
            origin,
        }
    }
}

/// Where a tool call came from. Policies may scope checks by origin; it grants
/// no authority.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolCallOrigin {
    AgentSession,
    Mcp,
}

/// One policy handler's verdict.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ToolPolicyDecision {
    /// Continue with the (possibly rewritten) call.
    Allow(ToolCall),
    /// Stop the policy chain; the call does not execute.
    Deny(ToolPolicyDenial),
}

/// Why a policy refused a tool call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToolPolicyDenial {
    pub code: ToolPolicyDenialCode,
    pub reason: String,
}

impl ToolPolicyDenial {
    pub fn new(code: ToolPolicyDenialCode, reason: impl Into<String>) -> Self {
        Self {
            code,
            reason: reason.into(),
        }
    }
}

impl std::fmt::Display for ToolPolicyDenial {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str(&self.reason)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ToolPolicyDenialCode {
    Mode,
    UntrustedProject,
    RateLimit,
    Policy,
}

impl ToolPolicyDenialCode {
    pub const fn raw_value(self) -> &'static str {
        match self {
            ToolPolicyDenialCode::Mode => "mode",
            ToolPolicyDenialCode::UntrustedProject => "untrustedProject",
            ToolPolicyDenialCode::RateLimit => "rateLimit",
            ToolPolicyDenialCode::Policy => "policy",
        }
    }
}

/// Returned when a tool policy handler denies a call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ToolPolicyError {
    Denied(ToolPolicyDenial),
    InvalidRewrite,
}

impl std::fmt::Display for ToolPolicyError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ToolPolicyError::Denied(denial) => formatter.write_str(&denial.reason),
            ToolPolicyError::InvalidRewrite => formatter.write_str(
                "tool policies may rewrite arguments, but cannot change the tool name or origin",
            ),
        }
    }
}

impl std::error::Error for ToolPolicyError {}

/// Ordered, short-circuiting policy chain evaluated before a tool call
/// executes.
///
/// Handlers run in registration order and may rewrite the call or stop it with
/// a denial. An empty policy is a pass-through, so hosts that register nothing
/// keep their exact previous behavior. Denials are surfaced to the caller as
/// [`ToolPolicyError::Denied`]; the AI session turns them into a tool-result
/// observation the model can react to, and MCP turns them into a failed tool
/// result.
#[derive(Clone)]
pub struct ToolPolicy {
    handlers: Vec<ToolPolicyHandler>,
}

pub type ToolPolicyHandler =
    Arc<dyn Fn(ToolCall) -> Result<ToolPolicyDecision, ToolPolicyError> + Send + Sync>;

impl Default for ToolPolicy {
    fn default() -> Self {
        Self::new(Vec::new())
    }
}

impl ToolPolicy {
    pub fn new(handlers: Vec<ToolPolicyHandler>) -> Self {
        Self { handlers }
    }

    pub fn appending(&self, handler: ToolPolicyHandler) -> ToolPolicy {
        let mut handlers = self.handlers.clone();
        handlers.push(handler);
        ToolPolicy::new(handlers)
    }

    /// Returns the call to execute (possibly rewritten). The first denial stops
    /// the chain; errors thrown by handlers propagate unchanged.
    pub fn evaluate(&self, call: ToolCall) -> Result<ToolCall, ToolPolicyError> {
        let expected_name = call.name.clone();
        let expected_origin = call.origin;
        let mut current = call;
        for handler in &self.handlers {
            match handler(current.clone())? {
                ToolPolicyDecision::Allow(next) => {
                    if next.name != expected_name || next.origin != expected_origin {
                        return Err(ToolPolicyError::InvalidRewrite);
                    }
                    current = next;
                }
                ToolPolicyDecision::Deny(denial) => return Err(ToolPolicyError::Denied(denial)),
            }
        }
        Ok(current)
    }
}

impl std::fmt::Debug for ToolPolicy {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ToolPolicy")
            .field("handlers", &self.handlers.len())
            .finish()
    }
}

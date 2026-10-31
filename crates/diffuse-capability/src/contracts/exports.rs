//! Canonical tool schemas are owned by the portable agent foundation.
//!
//! Swift wrote `@_exported import CoveUIAgentCore`; MIGRATION.md §3 maps that to
//! `cove-agent` (gap G6, closed). The vocabulary is re-exported through
//! `capability_contract::agent`.

pub use crate::capability_contract::agent::{
    AgentTool, JsonSchema, JsonSchemaScalar, JsonSchemaType, JsonSchemaValidator,
    JsonSchemaViolation, SessionApiFormat,
};

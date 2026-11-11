//! Unit tests for the Diffuse MCP bridge.
//!
//! Swift shipped no `DiffuseMCP` test target, so these pin the ported
//! behaviour: the editor's line protocol, capability discovery state and the
//! tool routing table.

mod capability_tools_tests;
mod editor_call_tests;
mod fixture;
mod invoke_tool_tests;
mod tool_descriptors_tests;

use std::collections::BTreeMap;

use serde_json::{Value, json};

use crate::{ActiveCapability, CapabilitySession};

fn session(snapshot_id: Option<&str>, capabilities: &[(&str, &str)]) -> CapabilitySession {
    let active_tools = capabilities
        .iter()
        .map(|(name, description)| {
            (
                (*name).to_string(),
                ActiveCapability {
                    description: (*description).to_string(),
                    schema: json!({ "type": "object" }),
                },
            )
        })
        .collect::<BTreeMap<_, _>>();
    CapabilitySession {
        active_tools,
        snapshot_id: snapshot_id.map(str::to_string),
    }
}

/// One `active_capabilities` entry as the editor advertises it.
fn capability(tool_name: &str, description: &str) -> Value {
    json!({
        "tool_name": tool_name,
        "description": description,
        "input_schema": { "type": "object" },
    })
}

fn tool_names(state: &CapabilitySession) -> Vec<&str> {
    state.active_tools.keys().map(String::as_str).collect()
}

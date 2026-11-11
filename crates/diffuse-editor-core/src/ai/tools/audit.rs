//! `Editor/Sources/EditorCore/AI/Tools/Audit.swift` — host tool policy for the
//! Editor.
//!
//! It is deliberately non-blocking: mutating project-tool calls from the
//! built-in assistant and the MCP bridge are recorded for diagnosis, while the
//! existing gates (workflow scope, project trust, review) keep enforcement.

use std::collections::BTreeMap;
use std::sync::Arc;

use cove_logging::{Level, LogEvent, LogSystem, LogValue};
use diffuse_ai::tools::project_toolset::ProjectToolset;
use diffuse_ai::tools::tool_policy::{
    ToolCall, ToolCallOrigin, ToolPolicy, ToolPolicyDecision, ToolPolicyError, ToolPolicyHandler,
};
use diffuse_plugin::base64_data::Data;
use serde_json::Value;

pub(crate) struct EditorToolAudit;

impl EditorToolAudit {
    /// Swift's `static let policy`.
    pub(crate) fn policy() -> ToolPolicy {
        let handler: ToolPolicyHandler = Arc::new(record_mutating_project_tool_calls);
        ToolPolicy::new(vec![handler])
    }

    /// Key names only: audit records never copy tool payloads (source code,
    /// paths, or credentials the model produced).
    fn argument_keys(arguments: &Data) -> String {
        match serde_json::from_slice::<Value>(arguments.as_slice()) {
            Ok(Value::Object(object)) if !object.is_empty() => {
                object.keys().cloned().collect::<Vec<String>>().join(",")
            }
            _ => "-".to_string(),
        }
    }
}

fn record_mutating_project_tool_calls(
    call: ToolCall,
) -> Result<ToolPolicyDecision, ToolPolicyError> {
    let Some(tool) = ProjectToolset::definition(&call.name) else {
        return Ok(ToolPolicyDecision::Allow(call));
    };
    if tool.read_only {
        return Ok(ToolPolicyDecision::Allow(call));
    }
    let origin = match call.origin {
        ToolCallOrigin::Mcp => "mcp",
        ToolCallOrigin::AgentSession => "agent",
    };
    let metadata: BTreeMap<String, LogValue> = BTreeMap::from([
        ("origin".to_string(), LogValue::from(origin)),
        ("tool".to_string(), LogValue::from(call.name.as_str())),
        (
            "arguments".to_string(),
            LogValue::from(EditorToolAudit::argument_keys(&call.arguments)),
        ),
        (
            "bytes".to_string(),
            LogValue::from(call.arguments.len().to_string()),
        ),
    ]);
    LogSystem::logger("com.cove.editor.tool-audit")
        .log(&LogEvent::new(Level::Info, "Mutating project tool call").with_metadata(metadata));
    Ok(ToolPolicyDecision::Allow(call))
}

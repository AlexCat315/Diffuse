//! Diffuse MCP server binary.
//!
//! Ported from `DiffuseMCP/Sources/DiffuseMCP/main.swift`: the MCP protocol
//! layer is Cove's, every tool call is forwarded to the running editor over a
//! localhost TCP JSON line, and capability discovery rebuilds the dynamic tool
//! table.

use std::collections::BTreeMap;
use std::io::{ErrorKind, Read, Write};
use std::net::{Ipv4Addr, SocketAddrV4, TcpStream};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use cove_agent::transport::{self, Handler, LineWriter};
use cove_agent::ui_tools::Tools as UIDiagnosticTools;
use cove_agent::{
    AgentError, AgentTool, AgentToolResult, JsonSchema, JsonSchemaType, McpServer, notification,
};
use diffuse_ai::tools::capability_toolset::CapabilityToolset;
use diffuse_ai::tools::project_toolset::ProjectToolset;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use diffuse_kernel::codable::new_uuid;
use serde_json::{Value, json};

/// Editor MCP bridge port used when `DIFFUSE_MCP_PORT` is absent.
const DEFAULT_EDITOR_PORT: u16 = 9898;
/// Socket read and write timeout for one editor call.
const EDITOR_TIMEOUT: Duration = Duration::from_secs(180);
/// Largest accepted editor response line.
const MAX_EDITOR_RESPONSE_BYTES: usize = 2_097_152;
/// Chunk size used while waiting for the response newline.
const READ_CHUNK_BYTES: usize = 8192;

const UNAVAILABLE_CAPABILITY_DESCRIPTION: &str = "Unavailable Diffuse editor capability";
const RELOAD_PLUGIN_DESCRIPTION: &str = "Re-mount an enabled plugin whose package (code, WIT, permissions, schemas, requirements) still matches its stored authorization. Changed packages are rejected until the user re-authorizes them in the Editor; this never authorizes on its own.";

// MARK: - IPC (TCP → editor on localhost)

fn failure(message: &str) -> Value {
    json!({ "ok": false, "error": message })
}

/// Send one request line to the editor and read one response line.
///
/// Failure shapes are the editor protocol's, not MCP's: every transport or
/// decoding error still returns an object with `ok: false` and `error`.
fn editor_call(port: u16, request: &Value) -> Value {
    let Ok(mut payload) = serde_json::to_vec(request) else {
        return failure("serialization error");
    };
    payload.push(b'\n');

    let address = SocketAddrV4::new(Ipv4Addr::LOCALHOST, port);
    let Ok(mut stream) = TcpStream::connect(address) else {
        return failure(&format!(
            "Diffuse is not running (could not connect to localhost:{port})"
        ));
    };
    let _ = stream.set_read_timeout(Some(EDITOR_TIMEOUT));
    let _ = stream.set_write_timeout(Some(EDITOR_TIMEOUT));

    if stream.write_all(&payload).is_err() {
        return failure("editor connection write failed");
    }

    let mut response = Vec::new();
    let mut chunk = [0u8; READ_CHUNK_BYTES];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => return failure("editor disconnected or response timed out"),
            Ok(count) => {
                response.extend_from_slice(&chunk[..count]);
                if response.len() > MAX_EDITOR_RESPONSE_BYTES {
                    return failure("editor response exceeds 2 MiB");
                }
                if let Some(newline) = response.iter().position(|&byte| byte == b'\n') {
                    response.truncate(newline);
                    break;
                }
            }
            Err(error) if error.kind() == ErrorKind::Interrupted => continue,
            Err(_) => return failure("editor disconnected or response timed out"),
        }
    }

    match serde_json::from_slice::<Value>(&response) {
        Ok(value) if value.is_object() => value,
        _ => failure("invalid response from editor"),
    }
}

// MARK: - Tool definitions

/// One active capability tool advertised by the editor.
struct ActiveCapability {
    description: String,
    schema: Value,
}

/// Capability discovery state shared by the listing and execution paths.
#[derive(Default)]
struct CapabilitySession {
    active_tools: BTreeMap<String, ActiveCapability>,
    snapshot_id: Option<String>,
}

fn lock(session: &Mutex<CapabilitySession>) -> MutexGuard<'_, CapabilitySession> {
    session
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// Swift's `as? [[String: Any]]`: an array whose elements are all objects.
fn object_array(value: Option<&Value>) -> Option<&Vec<Value>> {
    value
        .and_then(Value::as_array)
        .filter(|items| items.iter().all(Value::is_object))
}

/// Apply `active_capabilities`/`capabilities` from an editor response.
///
/// A new `snapshot_id` invalidates the previous dynamic table; otherwise the
/// discovered tools accumulate, as the host only ever adds contracts.
fn install_capability_tools(state: &mut CapabilitySession, response: &Value) {
    if response.get("ok").and_then(Value::as_bool) != Some(true) {
        return;
    }
    let snapshot_id = response.get("snapshot_id").and_then(Value::as_str);
    if snapshot_id.is_some_and(|snapshot_id| state.snapshot_id.as_deref() != Some(snapshot_id)) {
        state.active_tools.clear();
        state.snapshot_id = snapshot_id.map(str::to_string);
    }
    let capabilities = object_array(response.get("active_capabilities"))
        .or_else(|| object_array(response.get("capabilities")));
    let Some(capabilities) = capabilities else {
        return;
    };
    for capability in capabilities {
        let (Some(name), Some(description), Some(schema)) = (
            capability.get("tool_name").and_then(Value::as_str),
            capability.get("description").and_then(Value::as_str),
            capability.get("input_schema").and_then(Value::as_object),
        ) else {
            continue;
        };
        state.active_tools.insert(
            name.to_string(),
            ActiveCapability {
                description: description.to_string(),
                schema: Value::Object(schema.clone()),
            },
        );
    }
}

/// Build a framework tool from its capability contract.
fn framework_tool(registry: &CapabilityRegistry, capability_id: &str, name: &str) -> AgentTool {
    let Some(descriptor) = registry.descriptor(capability_id) else {
        return AgentTool::new(
            name,
            UNAVAILABLE_CAPABILITY_DESCRIPTION,
            JsonSchema {
                r#type: Some(JsonSchemaType::Object),
                ..JsonSchema::default()
            },
            false,
        );
    };
    let contract = descriptor.contract();
    AgentTool::new(name, contract.description, contract.input_schema, false)
}

fn reload_plugin_tool() -> AgentTool {
    AgentTool::new(
        "reload_plugin",
        RELOAD_PLUGIN_DESCRIPTION,
        JsonSchema::object(
            BTreeMap::from([("plugin_id".to_string(), JsonSchema::string(Some(1), None))]),
            vec!["plugin_id".to_string()],
        ),
        false,
    )
}

/// Project tools first, then the framework tools, then the sorted active ones.
fn tool_descriptors(
    registry: &CapabilityRegistry,
    session: &Mutex<CapabilitySession>,
    port: u16,
    session_id: &str,
) -> Result<Vec<AgentTool>, AgentError> {
    {
        let mut state = lock(session);
        if state.active_tools.is_empty() {
            let response = editor_call(
                port,
                &json!({
                    "action": "open_capability_session",
                    "session_id": session_id,
                }),
            );
            install_capability_tools(&mut state, &response);
        }
    }

    let mut tools = ProjectToolset::tools();
    tools.push(framework_tool(
        registry,
        "system.search_capabilities",
        CapabilityToolset::SEARCH_TOOL_NAME,
    ));
    tools.push(framework_tool(
        registry,
        "system.submit_plan",
        CapabilityToolset::SUBMIT_TOOL_NAME,
    ));
    tools.push(reload_plugin_tool());

    let state = lock(session);
    for (name, capability) in &state.active_tools {
        let schema =
            serde_json::from_value::<JsonSchema>(capability.schema.clone()).map_err(|_| {
                AgentError::InvalidConfiguration(format!(
                    "Invalid input schema for capability tool {name}."
                ))
            })?;
        tools.push(AgentTool::new(
            name.clone(),
            capability.description.clone(),
            schema,
            false,
        ));
    }
    Ok(tools)
}

/// Discovery metadata stays bounded; generated tool schemas travel through
/// `tools/list` rather than being repeated in this result.
fn capability_search_text(response: &Value) -> Value {
    let mut public = response.clone();
    let Some(object) = public.as_object_mut() else {
        return public;
    };
    object.remove("active_capabilities");
    let capabilities = object
        .get("capabilities")
        .and_then(Value::as_array)
        .cloned()
        .filter(|items| items.iter().all(Value::is_object));
    if let Some(capabilities) = capabilities {
        let trimmed = capabilities
            .into_iter()
            .map(|capability| {
                let mut metadata = capability;
                if let Some(metadata) = metadata.as_object_mut() {
                    metadata.remove("input_schema");
                }
                metadata
            })
            .collect();
        object.insert("capabilities".to_string(), Value::Array(trimmed));
    }
    public
}

fn invoke_tool(
    session: &Mutex<CapabilitySession>,
    notifier: &LineWriter,
    port: u16,
    session_id: &str,
    name: &str,
    input: &Value,
) -> Result<AgentToolResult, AgentError> {
    let arguments = input.as_object().cloned().unwrap_or_default();
    let is_project_tool = ProjectToolset::tools().iter().any(|tool| tool.name == name);
    let response = if is_project_tool {
        editor_call(
            port,
            &json!({
                "action": "project_tool",
                "tool_name": name,
                "arguments": Value::Object(arguments),
            }),
        )
    } else {
        match name {
            CapabilityToolset::SEARCH_TOOL_NAME => {
                let mut request = arguments;
                request.insert(
                    "action".to_string(),
                    Value::String("search_capabilities".to_string()),
                );
                request.insert(
                    "session_id".to_string(),
                    Value::String(session_id.to_string()),
                );
                let found = editor_call(port, &Value::Object(request));
                install_capability_tools(&mut lock(session), &found);
                if found.get("ok").and_then(Value::as_bool) == Some(true) {
                    let _ = notifier
                        .write_line(&notification("notifications/tools/list_changed", None));
                }
                capability_search_text(&found)
            }
            CapabilityToolset::SUBMIT_TOOL_NAME => {
                let mut request = arguments;
                request.insert(
                    "action".to_string(),
                    Value::String("submit_capability_plan".to_string()),
                );
                request.insert(
                    "session_id".to_string(),
                    Value::String(session_id.to_string()),
                );
                editor_call(port, &Value::Object(request))
            }
            "reload_plugin" => {
                let mut request = arguments;
                request.insert(
                    "action".to_string(),
                    Value::String("reload_plugin".to_string()),
                );
                editor_call(port, &Value::Object(request))
            }
            other => {
                if !lock(session).active_tools.contains_key(other) {
                    return Err(AgentError::UnknownTool(other.to_string()));
                }
                editor_call(
                    port,
                    &json!({
                        "action": "invoke_capability",
                        "session_id": session_id,
                        "tool_name": other,
                        "arguments": Value::Object(arguments),
                    }),
                )
            }
        }
    };

    let is_error = response.get("ok").and_then(Value::as_bool) != Some(true);
    let json = serde_json::to_vec(&response).map_err(|_| AgentError::InvalidResult)?;
    Ok(AgentToolResult::new(json, is_error))
}

// MARK: - Main loop

fn main() {
    let port = std::env::var("DIFFUSE_MCP_PORT")
        .ok()
        .and_then(|value| value.parse::<u16>().ok())
        .unwrap_or(DEFAULT_EDITOR_PORT);
    let session_id = new_uuid();
    let session = Arc::new(Mutex::new(CapabilitySession::default()));
    let registry = BuiltInTypedCapabilityCatalog::registry();

    let writer = LineWriter::stdout();
    let notifier = writer.clone();
    let list_session = Arc::clone(&session);
    let list_id = session_id.clone();
    let execute_session = Arc::clone(&session);
    let execute_id = session_id.clone();
    let server = McpServer::with_provider(
        "diffuse",
        "0.1.0",
        UIDiagnosticTools::skills(),
        move || tool_descriptors(&registry, &list_session, port, &list_id),
        move |name, input| invoke_tool(&execute_session, &notifier, port, &execute_id, name, input),
    );
    let handler: Handler = Arc::new(move |data: &[u8]| server.respond(data));

    let _ = transport::serve_lines(std::io::stdin().lock(), &writer, &handler);

    if lock(&session).snapshot_id.is_some() {
        let _ = editor_call(
            port,
            &json!({
                "action": "close_capability_session",
                "session_id": session_id,
            }),
        );
    }
}

#[cfg(test)]
mod tests;

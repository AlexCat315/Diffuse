use std::sync::Mutex;

use cove_agent::{AgentError, JsonSchemaType};
use diffuse_ai::tools::project_toolset::ProjectToolset;
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use serde_json::json;

use super::fixture::{MockEditor, json_line};
use super::session;
use crate::{CapabilitySession, RELOAD_PLUGIN_DESCRIPTION, reload_plugin_tool, tool_descriptors};

#[test]
fn tool_descriptors_orders_project_framework_and_dynamic_tools() {
    let registry = BuiltInTypedCapabilityCatalog::registry();
    let state = Mutex::new(session(
        Some("snap-1"),
        &[("zeta", "Z"), ("alpha", "A"), ("mu", "M")],
    ));
    let editor = MockEditor::start(|_| json_line(&json!({ "ok": true })));

    let tools = tool_descriptors(&registry, &state, editor.port(), "session-1")
        .expect("descriptors are built");

    let names: Vec<String> = tools.iter().map(|tool| tool.name.clone()).collect();
    let mut expected: Vec<String> = ProjectToolset::tools()
        .into_iter()
        .map(|tool| tool.name)
        .collect();
    expected.extend(
        [
            "search_capabilities",
            "submit_plan",
            "reload_plugin",
            "alpha",
            "mu",
            "zeta",
        ]
        .map(str::to_string),
    );
    assert_eq!(names, expected);

    let alpha = tools
        .iter()
        .find(|tool| tool.name == "alpha")
        .expect("dynamic tool is listed");
    assert_eq!(alpha.description, "A");
    assert_eq!(alpha.schema.r#type, Some(JsonSchemaType::Object));
    assert!(!alpha.read_only);

    let search = tools
        .iter()
        .find(|tool| tool.name == "search_capabilities")
        .expect("search tool is listed");
    assert!(!search.description.is_empty());
    assert!(!search.read_only);

    assert!(editor.requests().is_empty());
}

#[test]
fn tool_descriptors_opens_capability_session_on_first_use() {
    let registry = BuiltInTypedCapabilityCatalog::registry();
    let state = Mutex::new(CapabilitySession::default());
    let editor = MockEditor::start(|_| {
        json_line(&json!({
            "ok": true,
            "snapshot_id": "snap-1",
            "active_capabilities": [{
                "tool_name": "cap_a",
                "description": "Capability A",
                "input_schema": { "type": "object" },
            }],
        }))
    });

    let tools = tool_descriptors(&registry, &state, editor.port(), "session-1")
        .expect("descriptors are built");

    assert_eq!(
        editor.request_json(0),
        json!({ "action": "open_capability_session", "session_id": "session-1" })
    );
    assert!(tools.iter().any(|tool| tool.name == "cap_a"));

    let search = tools
        .iter()
        .find(|tool| tool.name == "search_capabilities")
        .expect("search tool is listed");
    let contract = registry
        .descriptor("system.search_capabilities")
        .expect("search capability is registered")
        .contract();
    assert_eq!(search.description, contract.description);

    let installed = state.lock().expect("session lock");
    assert_eq!(installed.snapshot_id.as_deref(), Some("snap-1"));
    assert!(installed.active_tools.contains_key("cap_a"));
}

#[test]
fn tool_descriptors_reuses_installed_capabilities_without_reopening() {
    let registry = BuiltInTypedCapabilityCatalog::registry();
    let state = Mutex::new(CapabilitySession::default());
    let editor = MockEditor::start(|_| {
        json_line(&json!({
            "ok": true,
            "snapshot_id": "snap-1",
            "active_capabilities": [{
                "tool_name": "cap_a",
                "description": "Capability A",
                "input_schema": { "type": "object" },
            }],
        }))
    });

    let first =
        tool_descriptors(&registry, &state, editor.port(), "session-1").expect("first listing");
    let second =
        tool_descriptors(&registry, &state, editor.port(), "session-1").expect("second listing");

    assert_eq!(editor.requests().len(), 1);
    assert!(first.iter().any(|tool| tool.name == "cap_a"));
    assert!(second.iter().any(|tool| tool.name == "cap_a"));
}

#[test]
fn tool_descriptors_keeps_listing_when_editor_is_unavailable() {
    let registry = BuiltInTypedCapabilityCatalog::registry();
    let state = Mutex::new(CapabilitySession::default());
    let editor = MockEditor::start(|_| Vec::new());

    let tools =
        tool_descriptors(&registry, &state, editor.port(), "session-1").expect("listing succeeds");

    assert_eq!(tools.len(), ProjectToolset::tools().len() + 3);
    assert_eq!(editor.requests().len(), 1);
    assert!(state.lock().expect("session lock").snapshot_id.is_none());
}

#[test]
fn tool_descriptors_rejects_invalid_dynamic_schema() {
    let registry = BuiltInTypedCapabilityCatalog::registry();
    let mut state = session(Some("snap-1"), &[]);
    state.active_tools.insert(
        "broken".to_string(),
        crate::ActiveCapability {
            description: "Broken".to_string(),
            schema: json!({ "type": 42 }),
        },
    );
    let state = Mutex::new(state);
    let editor = MockEditor::start(|_| json_line(&json!({ "ok": true })));

    let error = tool_descriptors(&registry, &state, editor.port(), "session-1")
        .expect_err("invalid schema fails the listing");

    assert_eq!(
        error,
        AgentError::InvalidConfiguration(
            "Invalid input schema for capability tool broken.".to_string()
        )
    );
}

#[test]
fn reload_plugin_tool_requires_plugin_id() {
    let tool = reload_plugin_tool();

    assert_eq!(tool.name, "reload_plugin");
    assert_eq!(tool.description, RELOAD_PLUGIN_DESCRIPTION);
    assert_eq!(tool.schema.required, ["plugin_id"]);
    assert!(tool.schema.properties.contains_key("plugin_id"));
    assert_eq!(tool.schema.additional_properties, Some(false));
    assert!(!tool.read_only);
}

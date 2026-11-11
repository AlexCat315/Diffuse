use cove_agent::{JsonSchema, JsonSchemaType};
use diffuse_intent::BuiltInTypedCapabilityCatalog;
use serde_json::json;

use super::{capability, session, tool_names};
use crate::{
    UNAVAILABLE_CAPABILITY_DESCRIPTION, capability_search_text, framework_tool,
    install_capability_tools,
};

#[test]
fn install_capability_tools_ignores_unsuccessful_response() {
    let mut state = session(Some("snap-1"), &[("alpha", "A")]);

    install_capability_tools(
        &mut state,
        &json!({
            "ok": false,
            "snapshot_id": "snap-2",
            "active_capabilities": [capability("beta", "B")],
        }),
    );
    install_capability_tools(
        &mut state,
        &json!({ "active_capabilities": [capability("gamma", "G")] }),
    );

    assert_eq!(tool_names(&state), ["alpha"]);
    assert_eq!(state.snapshot_id.as_deref(), Some("snap-1"));
    assert_eq!(state.active_tools["alpha"].description, "A");
}

#[test]
fn install_capability_tools_accumulates_within_same_snapshot() {
    let mut state = session(Some("snap-1"), &[("alpha", "A")]);

    install_capability_tools(
        &mut state,
        &json!({
            "ok": true,
            "snapshot_id": "snap-1",
            "active_capabilities": [capability("beta", "B")],
        }),
    );

    assert_eq!(tool_names(&state), ["alpha", "beta"]);
    assert_eq!(state.snapshot_id.as_deref(), Some("snap-1"));
}

#[test]
fn install_capability_tools_clears_on_new_snapshot() {
    let mut state = session(Some("snap-1"), &[("alpha", "A"), ("beta", "B")]);

    install_capability_tools(
        &mut state,
        &json!({
            "ok": true,
            "snapshot_id": "snap-2",
            "active_capabilities": [capability("gamma", "G")],
        }),
    );

    assert_eq!(tool_names(&state), ["gamma"]);
    assert_eq!(state.snapshot_id.as_deref(), Some("snap-2"));
    assert_eq!(state.active_tools["gamma"].description, "G");
}

#[test]
fn install_capability_tools_keeps_previous_snapshot_when_response_omits_it() {
    let mut state = session(Some("snap-1"), &[("alpha", "A")]);

    install_capability_tools(
        &mut state,
        &json!({ "ok": true, "active_capabilities": [capability("beta", "B")] }),
    );

    assert_eq!(tool_names(&state), ["alpha", "beta"]);
    assert_eq!(state.snapshot_id.as_deref(), Some("snap-1"));
}

#[test]
fn install_capability_tools_prefers_active_capabilities() {
    let mut state = session(None, &[]);

    install_capability_tools(
        &mut state,
        &json!({
            "ok": true,
            "snapshot_id": "snap-1",
            "active_capabilities": [capability("active", "Active")],
            "capabilities": [capability("legacy", "Legacy")],
        }),
    );

    assert_eq!(tool_names(&state), ["active"]);
}

#[test]
fn install_capability_tools_skips_malformed_entries() {
    let mut state = session(None, &[]);

    install_capability_tools(
        &mut state,
        &json!({
            "ok": true,
            "snapshot_id": "snap-1",
            "active_capabilities": [
                capability("good", "Good"),
                { "tool_name": "no_description", "input_schema": { "type": "object" } },
                { "tool_name": "no_schema", "description": "D" },
                { "tool_name": "schema_not_object", "description": "D", "input_schema": 3 },
                { "description": "D", "input_schema": { "type": "object" } },
                {
                    "tool_name": "good_2",
                    "description": "Good 2",
                    "input_schema": { "type": "object" },
                    "unexpected": true,
                },
            ],
        }),
    );

    assert_eq!(tool_names(&state), ["good", "good_2"]);
    assert_eq!(
        state.active_tools["good_2"].schema,
        json!({ "type": "object" })
    );
}

#[test]
fn install_capability_tools_falls_back_when_active_list_is_invalid() {
    let mut state = session(None, &[]);

    install_capability_tools(
        &mut state,
        &json!({
            "ok": true,
            "snapshot_id": "snap-1",
            "active_capabilities": ["not an object"],
            "capabilities": [capability("legacy", "Legacy")],
        }),
    );

    assert_eq!(tool_names(&state), ["legacy"]);
}

#[test]
fn install_capability_tools_treats_empty_active_list_as_authoritative() {
    let mut state = session(None, &[]);

    install_capability_tools(
        &mut state,
        &json!({
            "ok": true,
            "snapshot_id": "snap-1",
            "active_capabilities": [],
            "capabilities": [capability("legacy", "Legacy")],
        }),
    );

    assert!(state.active_tools.is_empty());
    assert_eq!(state.snapshot_id.as_deref(), Some("snap-1"));
}

#[test]
fn install_capability_tools_overwrites_existing_tool_definition() {
    let mut state = session(Some("snap-1"), &[("alpha", "A")]);

    install_capability_tools(
        &mut state,
        &json!({
            "ok": true,
            "snapshot_id": "snap-1",
            "active_capabilities": [
                {
                    "tool_name": "alpha",
                    "description": "A2",
                    "input_schema": { "type": "object", "required": ["x"] },
                },
            ],
        }),
    );

    assert_eq!(tool_names(&state), ["alpha"]);
    assert_eq!(state.active_tools["alpha"].description, "A2");
    assert_eq!(
        state.active_tools["alpha"].schema,
        json!({ "type": "object", "required": ["x"] })
    );
}

#[test]
fn framework_tool_uses_registry_contract() {
    let registry = BuiltInTypedCapabilityCatalog::registry();
    let contract = registry
        .descriptor("system.search_capabilities")
        .expect("search capability is registered")
        .contract();

    let tool = framework_tool(
        &registry,
        "system.search_capabilities",
        "search_capabilities",
    );

    assert_eq!(tool.name, "search_capabilities");
    assert_eq!(tool.description, contract.description);
    assert_eq!(tool.schema, contract.input_schema);
    assert!(!tool.read_only);
}

#[test]
fn framework_tool_falls_back_when_capability_is_missing() {
    let registry = BuiltInTypedCapabilityCatalog::registry();

    let tool = framework_tool(&registry, "system.missing_capability", "missing_capability");

    assert_eq!(tool.name, "missing_capability");
    assert_eq!(tool.description, UNAVAILABLE_CAPABILITY_DESCRIPTION);
    assert_eq!(
        tool.schema,
        JsonSchema {
            r#type: Some(JsonSchemaType::Object),
            ..JsonSchema::default()
        }
    );
    assert!(!tool.read_only);
}

#[test]
fn capability_search_text_removes_schemas_and_active_list() {
    let response = json!({
        "ok": true,
        "snapshot_id": "snap-1",
        "active_capabilities": [capability("active", "Active")],
        "capabilities": [
            { "id": "cap_a", "title": "A", "input_schema": { "type": "object" } },
            { "id": "cap_b", "title": "B" },
        ],
        "other": 7,
    });

    let public = capability_search_text(&response);

    assert_eq!(public["ok"], true);
    assert_eq!(public["snapshot_id"], "snap-1");
    assert_eq!(public["other"], 7);
    assert!(public.get("active_capabilities").is_none());
    assert!(public["capabilities"][0].get("input_schema").is_none());
    assert_eq!(public["capabilities"][0]["id"], "cap_a");
    assert_eq!(public["capabilities"][1]["title"], "B");
}

#[test]
fn capability_search_text_leaves_non_object_entries_intact() {
    let response = json!({
        "ok": true,
        "capabilities": [
            { "id": "cap_a", "input_schema": { "type": "object" } },
            "not an object",
        ],
    });

    let public = capability_search_text(&response);

    assert_eq!(public, response);
}

#[test]
fn capability_search_text_keeps_capabilities_when_not_an_array() {
    let response = json!({ "ok": true, "capabilities": "nope" });

    let public = capability_search_text(&response);

    assert_eq!(public, response);
}

#[test]
fn capability_search_text_returns_non_object_unchanged() {
    let response = json!([1, 2, 3]);

    assert_eq!(capability_search_text(&response), response);
}

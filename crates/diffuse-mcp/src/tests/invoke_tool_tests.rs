use std::sync::Mutex;

use cove_agent::AgentError;
use cove_agent::transport::LineWriter;
use serde_json::{Value, json};

use super::fixture::{CapturedWriter, MockEditor, json_line};
use super::{capability, session, tool_names};
use crate::{CapabilitySession, invoke_tool};

fn line_writer() -> (CapturedWriter, LineWriter) {
    let capture = CapturedWriter::default();
    let writer = LineWriter::new(capture.clone());
    (capture, writer)
}

fn run(
    state: &Mutex<CapabilitySession>,
    notifier: &LineWriter,
    port: u16,
    name: &str,
    input: Value,
) -> Result<cove_agent::AgentToolResult, AgentError> {
    invoke_tool(state, notifier, port, "session-1", name, &input)
}

#[test]
fn invoke_tool_rejects_unknown_tool_without_contacting_editor() {
    let state = Mutex::new(CapabilitySession::default());
    let (_capture, notifier) = line_writer();
    let editor = MockEditor::start(|_| json_line(&json!({ "ok": true })));

    let result = run(&state, &notifier, editor.port(), "ghost", json!({}));

    assert_eq!(result, Err(AgentError::UnknownTool("ghost".to_string())));
    assert!(editor.requests().is_empty());
}

#[test]
fn invoke_tool_forwards_project_tool_action_and_arguments() {
    let state = Mutex::new(CapabilitySession::default());
    let (_capture, notifier) = line_writer();
    let editor = MockEditor::start(|_| json_line(&json!({ "ok": true, "messages": [] })));

    let result = run(
        &state,
        &notifier,
        editor.port(),
        "get_console_messages",
        json!({ "limit": 5 }),
    )
    .expect("project tool is invoked");

    assert_eq!(
        editor.request_json(0),
        json!({
            "action": "project_tool",
            "tool_name": "get_console_messages",
            "arguments": { "limit": 5 },
        })
    );
    assert!(!result.is_error);
    assert_eq!(result.value(), Some(json!({ "ok": true, "messages": [] })));
}

#[test]
fn invoke_tool_defaults_project_arguments_to_empty_object() {
    let state = Mutex::new(CapabilitySession::default());
    let (_capture, notifier) = line_writer();
    let editor = MockEditor::start(|_| json_line(&json!({ "ok": true })));

    run(
        &state,
        &notifier,
        editor.port(),
        "list_files",
        json!(["not", "an", "object"]),
    )
    .expect("project tool is invoked");

    assert_eq!(
        editor.request_json(0),
        json!({
            "action": "project_tool",
            "tool_name": "list_files",
            "arguments": {},
        })
    );
}

#[test]
fn invoke_tool_search_installs_capabilities_notifies_and_hides_schemas() {
    let state = Mutex::new(CapabilitySession::default());
    let (capture, notifier) = line_writer();
    let editor = MockEditor::start(|_| {
        json_line(&json!({
            "ok": true,
            "snapshot_id": "snap-1",
            "active_capabilities": [capability("cap_a", "Capability A")],
            "capabilities": [
                { "id": "cap_a", "title": "A", "input_schema": { "type": "object" } },
            ],
        }))
    });

    let result = run(
        &state,
        &notifier,
        editor.port(),
        "search_capabilities",
        json!({ "query": "light" }),
    )
    .expect("search is invoked");

    assert_eq!(
        editor.request_json(0),
        json!({
            "query": "light",
            "action": "search_capabilities",
            "session_id": "session-1",
        })
    );
    assert!(!result.is_error);
    let value = result.value().expect("search result is JSON");
    assert_eq!(value["snapshot_id"], "snap-1");
    assert!(value.get("active_capabilities").is_none());
    assert!(value["capabilities"][0].get("input_schema").is_none());
    assert_eq!(value["capabilities"][0]["id"], "cap_a");
    assert_eq!(tool_names(&state.lock().expect("session lock")), ["cap_a"]);

    let lines = capture.lines();
    assert_eq!(lines.len(), 1);
    let notification: Value = serde_json::from_str(&lines[0]).expect("notification is JSON");
    assert_eq!(notification["jsonrpc"], "2.0");
    assert_eq!(notification["method"], "notifications/tools/list_changed");
    assert!(notification.get("params").is_none());
}

#[test]
fn invoke_tool_search_skips_notification_on_failure() {
    let state = Mutex::new(CapabilitySession::default());
    let (capture, notifier) = line_writer();
    let response = json!({
        "ok": false,
        "error": "editor rejected the search",
        "active_capabilities": [capability("cap_a", "Capability A")],
    });
    let editor = MockEditor::start(move |_| json_line(&response));

    let result = run(
        &state,
        &notifier,
        editor.port(),
        "search_capabilities",
        json!({}),
    )
    .expect("search is invoked");

    assert!(result.is_error);
    assert_eq!(
        result.value(),
        Some(json!({
            "ok": false,
            "error": "editor rejected the search",
        }))
    );
    assert!(capture.lines().is_empty());
    assert!(state.lock().expect("session lock").active_tools.is_empty());
}

#[test]
fn invoke_tool_search_overrides_caller_action_and_session() {
    let state = Mutex::new(CapabilitySession::default());
    let (_capture, notifier) = line_writer();
    let editor = MockEditor::start(|_| json_line(&json!({ "ok": true })));

    run(
        &state,
        &notifier,
        editor.port(),
        "search_capabilities",
        json!({ "query": "mesh", "action": "invoke_capability", "session_id": "spoofed" }),
    )
    .expect("search is invoked");

    assert_eq!(
        editor.request_json(0),
        json!({
            "query": "mesh",
            "action": "search_capabilities",
            "session_id": "session-1",
        })
    );
}

#[test]
fn invoke_tool_submit_plan_routes_arguments_unchanged() {
    let state = Mutex::new(CapabilitySession::default());
    let (_capture, notifier) = line_writer();
    let response = json!({
        "ok": true,
        "active_capabilities": [capability("cap_a", "Capability A")],
        "capabilities": [{ "id": "cap_a", "input_schema": { "type": "object" } }],
    });
    let editor = MockEditor::start({
        let response = response.clone();
        move |_| json_line(&response)
    });

    let result = run(
        &state,
        &notifier,
        editor.port(),
        "submit_plan",
        json!({ "summary": "S", "draft_ids": ["draft-1"] }),
    )
    .expect("submit is invoked");

    assert_eq!(
        editor.request_json(0),
        json!({
            "summary": "S",
            "draft_ids": ["draft-1"],
            "action": "submit_capability_plan",
            "session_id": "session-1",
        })
    );
    assert!(!result.is_error);
    assert_eq!(result.value(), Some(response));
}

#[test]
fn invoke_tool_reload_plugin_routes_plugin_id() {
    let state = Mutex::new(CapabilitySession::default());
    let (_capture, notifier) = line_writer();
    let editor = MockEditor::start(|_| json_line(&json!({ "ok": true, "reloaded": "plugin-1" })));

    let result = run(
        &state,
        &notifier,
        editor.port(),
        "reload_plugin",
        json!({ "plugin_id": "plugin-1" }),
    )
    .expect("reload is invoked");

    assert_eq!(
        editor.request_json(0),
        json!({ "plugin_id": "plugin-1", "action": "reload_plugin" })
    );
    assert!(!result.is_error);
    assert_eq!(
        result.value(),
        Some(json!({ "ok": true, "reloaded": "plugin-1" }))
    );
}

#[test]
fn invoke_tool_forwards_installed_capability() {
    let state = Mutex::new(session(Some("snap-1"), &[("cap_a", "Capability A")]));
    let (_capture, notifier) = line_writer();
    let editor = MockEditor::start(|_| json_line(&json!({ "ok": true, "draft_id": "draft-1" })));

    let result = run(
        &state,
        &notifier,
        editor.port(),
        "cap_a",
        json!({ "value": 1 }),
    )
    .expect("installed capability is invoked");

    assert_eq!(
        editor.request_json(0),
        json!({
            "action": "invoke_capability",
            "session_id": "session-1",
            "tool_name": "cap_a",
            "arguments": { "value": 1 },
        })
    );
    assert!(!result.is_error);
    assert_eq!(
        result.value(),
        Some(json!({ "ok": true, "draft_id": "draft-1" }))
    );
}

#[test]
fn invoke_tool_rejects_uninstalled_capability_without_contacting_editor() {
    let state = Mutex::new(session(Some("snap-1"), &[("cap_a", "Capability A")]));
    let (_capture, notifier) = line_writer();
    let editor = MockEditor::start(|_| json_line(&json!({ "ok": true })));

    let result = run(&state, &notifier, editor.port(), "cap_b", json!({}));

    assert_eq!(result, Err(AgentError::UnknownTool("cap_b".to_string())));
    assert!(editor.requests().is_empty());
}

#[test]
fn invoke_tool_reports_editor_failure_as_tool_error() {
    let state = Mutex::new(CapabilitySession::default());
    let (_capture, notifier) = line_writer();
    let response = json!({ "ok": false, "error": "list_files failed" });
    let editor = MockEditor::start({
        let response = response.clone();
        move |_| json_line(&response)
    });

    let result = run(&state, &notifier, editor.port(), "list_files", json!({}))
        .expect("project tool is invoked");

    assert!(result.is_error);
    assert_eq!(result.value(), Some(response));
}

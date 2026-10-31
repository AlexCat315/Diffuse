//! Ported from `Engine/Tests/PluginRuntimeTests/WorkbenchContributionTests.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_capability::capability_registry::CapabilityRegistry;

use crate::contract::bun_plugin_contract::BunPluginContract;
use crate::contract::plugin_contract::PluginContract;
use crate::contract::plugin_json::PluginJSON;
use crate::contract::plugin_manifest::{PluginManifestValidationError, PluginManifestValidator};
use crate::contract::plugin_package::ValidatedPluginPackage;
use crate::contribution::ai::agent::AgentContributionPoint;
use crate::contribution::ai::context::{AIContextContribution, AIContextContributionPoint};
use crate::contribution::ai::harness::{AIHarnessContribution, AIHarnessContributionPoint};
use crate::contribution::ai::tool::{AIToolContribution, AIToolContributionPoint};
use crate::contribution::registry::{ContributionPointRegistry, ContributionPointSpec};
use crate::contribution::workbench::command::{
    CommandContribution, CommandContributionPoint, PluginCommandResult, PluginWorkbenchResultError,
};
use crate::contribution::workbench::document::{
    DocumentViewContribution, DocumentViewContributionPoint,
};
use crate::contribution::workbench::panel::{
    PanelContent, PanelContribution, PanelContributionPoint,
};
use crate::contribution::workbench::placement::{MenuContributionPoint, ToolbarContributionPoint};
use crate::contribution::workbench::tree::UINode;
use crate::contribution::workbench::view::{PluginViewResult, UIEffect, UIEvent};

fn manifest(contributes: &str) -> Vec<u8> {
    format!(
        r#"{{
        "id": "test.workbench", "version": 1, "name": "Workbench", "description": "fixture",
         "access": "read", "imports": [], "composable_host_capabilities": [],
         "contributes": {contributes}}}"#
    )
    .into_bytes()
}

fn decode(
    contributes: &str,
) -> Result<crate::contract::plugin_manifest::CovePluginManifest, PluginManifestValidationError> {
    PluginManifestValidator::decode_and_validate(
        &manifest(contributes),
        &CapabilityRegistry::default_registry(),
        &ContributionPointRegistry::standard(),
    )
}

fn contract(document: &str) -> PluginContract {
    BunPluginContract::decode(document.as_bytes(), &[])
        .unwrap_or_else(|error| panic!("contract decodes: {error}"))
}

// @Test("a panel shows either a host view or content its entry point describes")
#[test]
fn panel_content_is_exclusive() {
    let valid = decode(
        r#"
        {"cove.ui.panel/v1": [
          {"id": "intent-input", "title": "Harness", "slot": "trailing", "icon": "ai-intent", "entryPoint": "panel", "surface": "assistant"},
          {"id": "status", "title": "Status", "entryPoint": "panel"}]}
        "#,
    )
    .expect("valid panels");
    let panels = valid
        .contributes
        .decode::<PanelContributionPoint>()
        .expect("decodes panels");
    assert_eq!(
        panels
            .iter()
            .map(PanelContribution::content)
            .collect::<Vec<_>>(),
        vec![
            PanelContent::EntryPoint("panel".to_string()),
            PanelContent::EntryPoint("panel".to_string())
        ]
    );

    for invalid in [
        r#"{"id": "x", "title": "X"}"#,
        r#"{"id": "x", "title": "X", "view": "agent", "entryPoint": "panel"}"#,
        r#"{"id": "x", "title": "X", "view": "agent", "slot": "middle"}"#,
        r#"{"id": "x", "title": "X", "view": "Agent View"}"#,
    ] {
        assert_eq!(
            decode(&format!(r#"{{"cove.ui.panel/v1": [{invalid}]}}"#)),
            Err(PluginManifestValidationError::InvalidContribution(
                PanelContributionPoint::ID.to_string()
            )),
            "{invalid} must be rejected"
        );
    }
    let mut region = PanelContribution::new(
        "context",
        "Context",
        PanelContent::EntryPoint("panel".to_string()),
    );
    region.slot = Some("trailing".to_string());
    region.in_surface = Some("example.owner.chat".to_string());
    PanelContributionPoint::validate(&region, &Default::default()).expect("region valid");
    region.surface = Some("also-a-mode".to_string());
    assert_eq!(
        PanelContributionPoint::validate(&region, &Default::default()),
        Err(PluginManifestValidationError::InvalidContribution(
            PanelContributionPoint::ID.to_string()
        ))
    );
}

// @Test("command and panel entry points must take the inputs the host sends")
#[test]
fn entry_points_match_their_inputs() {
    let runtime = contract(
        r#"{"version":1,"entries":[{"name":"command","title":"command","description":"","input":{"record":{"command":"string","arguments":"string"}}},{"name":"panel","title":"panel","description":"","input":{"record":{"view":"string","state":"string","event":"string","context":"string"}}}]}"#,
    );
    let command = CommandContribution::new("refresh", "Refresh", "command");
    let panel = PanelContribution::new(
        "status",
        "Status",
        PanelContent::EntryPoint("panel".to_string()),
    );
    CommandContributionPoint::validate_runtime(&command, Some(&runtime)).expect("command valid");
    PanelContributionPoint::validate_runtime(&panel, Some(&runtime)).expect("panel valid");

    let mut swapped = command;
    swapped.entry_point = "panel".to_string();
    assert_eq!(
        CommandContributionPoint::validate_runtime(&swapped, Some(&runtime)),
        Err(PluginManifestValidationError::InvalidContribution(
            CommandContributionPoint::ID.to_string()
        ))
    );
    assert_eq!(
        PanelContributionPoint::validate_runtime(&panel, None),
        Err(PluginManifestValidationError::InvalidContribution(
            PanelContributionPoint::ID.to_string()
        ))
    );
}

// @Test("command and panel entry points are called by the editor, never offered to the model")
#[test]
fn entry_points_stay_away_from_ai() {
    let manifest = decode(
        r#"
        {"cove.command/v1": [{"id": "refresh", "title": "Refresh", "entryPoint": "command", "palette": false}],
         "cove.ui.panel/v1": [{"id": "status", "title": "Status", "entryPoint": "panel"}],
         "cove.ai.tool/v1": [{"entryPoint": "inspect", "title": "Inspect", "description": "Reads the scene."}]}
        "#,
    )
    .expect("valid manifest");
    assert!(!manifest.exposes_to_ai("command"));
    assert!(!manifest.exposes_to_ai("panel"));
    assert!(!manifest.exposes_to_ai("undeclared"));
    assert!(manifest.exposes_to_ai("inspect"));
    assert_eq!(
        manifest.ai_tool("inspect").map(|tool| tool.description),
        Some("Reads the scene.".to_string())
    );
    assert_eq!(
        manifest
            .contributes
            .decode::<CommandContributionPoint>()
            .expect("decodes commands")
            .first()
            .and_then(|command| command.palette),
        Some(false)
    );
}

// @Test("menus, the toolbar, document views and AI context are validated")
#[test]
fn placements_and_views_are_validated() {
    let valid = decode(
        r#"
        {"cove.ui.menu/v1": [{"command": "refresh", "menu": "run"}],
         "cove.ui.toolbar/v1": [{"command": "refresh", "icon": "toolbar-arrow-path"}],
         "cove.ui.documentView/v1": [{"id": "table", "title": "Table", "extensions": ["csv"], "entryPoint": "document"}],
         "cove.ai.context/v1": [{"id": "summary", "title": "Summary", "entryPoint": "context", "maxBytes": 2048}]}
        "#,
    )
    .expect("valid placements");
    assert_eq!(
        valid
            .contributes
            .decode::<DocumentViewContributionPoint>()
            .expect("decodes views")
            .first()
            .map(|view| view.extensions.clone()),
        Some(vec!["csv".to_string()])
    );
    assert_eq!(
        valid
            .contributes
            .decode::<AIContextContributionPoint>()
            .expect("decodes contexts")
            .first()
            .map(AIContextContribution::byte_limit),
        Some(2048)
    );

    let invalid_cases: [(&str, &str); 6] = [
        (
            MenuContributionPoint::ID,
            r#"{"command": "refresh", "menu": "tools"}"#,
        ),
        (
            ToolbarContributionPoint::ID,
            r#"{"command": "refresh", "icon": "Arrow Path"}"#,
        ),
        (
            DocumentViewContributionPoint::ID,
            r#"{"id": "table", "title": "Table", "extensions": [], "entryPoint": "document"}"#,
        ),
        (
            DocumentViewContributionPoint::ID,
            r#"{"id": "table", "title": "Table", "extensions": ["CSV"], "entryPoint": "document"}"#,
        ),
        (
            AIContextContributionPoint::ID,
            r#"{"id": "summary", "title": "Summary", "entryPoint": "context", "maxBytes": 99999}"#,
        ),
        (
            AIToolContributionPoint::ID,
            r#"{"entryPoint": "components", "title": "Components", "description": "x"}"#,
        ),
    ];
    for (point, invalid) in invalid_cases {
        assert_eq!(
            decode(&format!(r#"{{"{point}": [{invalid}]}}"#)),
            Err(PluginManifestValidationError::InvalidContribution(
                point.to_string()
            )),
            "{point} / {invalid} must be rejected"
        );
    }

    let runtime = contract(
        r#"{"version":1,"entries":[{"name":"document","title":"document","description":"","input":{"record":{"view":"string","state":"string","event":"string","context":"string"}}},{"name":"context","title":"context","description":"","input":{"record":{"content":"string","selection":"string"}}}]}"#,
    );
    let view = DocumentViewContribution::new("table", "Table", vec!["csv".to_string()], "document");
    DocumentViewContributionPoint::validate_runtime(&view, Some(&runtime)).expect("view valid");
    AIContextContributionPoint::validate_runtime(
        &AIContextContribution::new("summary", "Summary", "context"),
        Some(&runtime),
    )
    .expect("context valid");
    AIToolContributionPoint::validate_runtime(
        &AIToolContribution::new("document", "Doc", "x"),
        Some(&runtime),
    )
    .expect("tool valid");
    assert_eq!(
        AIToolContributionPoint::validate_runtime(
            &AIToolContribution::new("missing", "Missing", "x"),
            Some(&runtime)
        ),
        Err(PluginManifestValidationError::InvalidContribution(
            AIToolContributionPoint::ID.to_string()
        ))
    );
    assert_eq!(
        AIContextContributionPoint::validate_runtime(
            &AIContextContribution::new("summary", "Summary", "document"),
            Some(&runtime)
        ),
        Err(PluginManifestValidationError::InvalidContribution(
            AIContextContributionPoint::ID.to_string()
        ))
    );
}

// @Test("a view result carries a component tree, the state to hand back and effects")
#[test]
fn view_result_is_decoded() {
    let result = PluginViewResult::from_json(
        br#"
        {"state": {"items": ["Ship"]},
         "ui": {"type": "column", "spacing": 8, "fillWidth": true, "maxWidth": 820, "children": [
           {"type": "textField", "id": "draft", "placeholder": "New item", "value": "", "submit": "add"},
           {"type": "row", "align": "center", "children": [
             {"type": "toggle", "id": "done-0", "value": true, "action": "toggle"},
             {"type": "text", "text": "Ship", "tone": "muted", "flex": 1},
             {"type": "button", "title": "Remove", "style": "ghost", "action": "remove", "arguments": {"index": 0}}]},
           {"type": "select", "id": "filter", "value": "all", "options": [{"value": "all", "label": "All"}]},
           {"type": "disclosure", "title": "More", "expanded": false, "action": "expand", "children": [
             {"type": "table", "columns": ["a", "b"], "rows": [{"cells": ["1", "2"], "action": "pick"}]}]},
           {"type": "progress", "percent": 40}, {"type": "spacer"}, {"type": "badge", "text": "1 open"}]},
         "effects": [{"type": "message", "text": "Added"}, {"type": "panel", "id": "checklist"},
                     {"type": "open", "path": "notes/todo.md"}]}
        "#,
        &BTreeSet::from(["checklist".to_string()]),
    )
    .expect("view result decodes");
    assert_eq!(
        result.state,
        Some(PluginJSON::Object(BTreeMap::from([(
            "items".to_string(),
            PluginJSON::Array(vec![PluginJSON::String("Ship".to_string())])
        )])))
    );
    assert_eq!(
        result.effects,
        vec![
            UIEffect::Message("Added".to_string()),
            UIEffect::Panel("checklist".to_string()),
            UIEffect::Open("notes/todo.md".to_string())
        ]
    );
    let crate::contribution::workbench::tree::UINodeKind::Column(stack) = &result.ui.kind else {
        panic!("not a column");
    };
    assert_eq!(stack.spacing, 8);
    assert_eq!(stack.children.len(), 7);
    assert_eq!(result.ui.fill_width, Some(true));
    assert_eq!(result.ui.max_width, Some(820));
    let crate::contribution::workbench::tree::UINodeKind::TextField(field) =
        &stack.children[0].kind
    else {
        panic!("not a field");
    };
    assert_eq!(field.submit.as_deref(), Some("add"));
    assert_eq!(field.value.as_deref(), Some(""));

    let unchanged = PluginViewResult::from_json(br#"{"ui": {"type": "spacer"}}"#, &BTreeSet::new())
        .expect("minimal view decodes");
    assert_eq!(unchanged.state, None);
    assert!(unchanged.effects.is_empty());
}

// @Test("view results stay within bounds and name only what the host knows")
#[test]
fn view_result_is_validated() {
    fn ui(node: &str) -> Vec<u8> {
        format!(r#"{{"ui": {node}}}"#).into_bytes()
    }
    let deep = format!(
        "{}{}{}",
        r#"{"type": "column", "children": ["#.repeat(30),
        r#"{"type": "spacer"}"#,
        "]}".repeat(30)
    );
    let invalid: Vec<Vec<u8>> = vec![
        ui(r#"{"type": "canvas"}"#),
        ui(r#"{"type": "button", "action": "add"}"#),
        ui(r#"{"type": "button", "title": "Go", "action": "Not An Action"}"#),
        ui(
            r#"{"type": "column", "children": [{"type": "toggle", "id": "a", "value": true}, {"type": "toggle", "id": "a", "value": false}]}"#,
        ),
        ui(
            r#"{"type": "select", "id": "s", "value": "missing", "options": [{"value": "a", "label": "A"}]}"#,
        ),
        ui(r#"{"type": "table", "columns": ["a", "b"], "rows": [{"cells": ["only one"]}]}"#),
        ui(r#"{"type": "column", "spacing": 99, "children": []}"#),
        ui(r#"{"type": "progress", "percent": 140}"#),
        ui(r#"{"type": "button", "title": "Go", "action": "go", "arguments": [1]}"#),
        ui(r#"{"type": "icon", "name": "../escape"}"#),
        ui(&deep),
        br#"{"ui": {"type": "spacer"}, "effects": [{"type": "panel", "id": "terminal"}]}"#.to_vec(),
        br#"{"ui": {"type": "spacer"}, "effects": [{"type": "open", "path": "../secrets"}]}"#
            .to_vec(),
        br#"{"ui": {"type": "spacer"}, "effects": [{"type": "open", "path": "/etc/hosts"}]}"#
            .to_vec(),
        format!(
            r#"{{"ui": {{"type": "spacer"}}, "state": "{}"}}"#,
            "x".repeat(50_000)
        )
        .into_bytes(),
        b"not json".to_vec(),
    ];
    for data in invalid {
        assert!(
            matches!(
                PluginViewResult::from_json(&data, &BTreeSet::from(["checklist".to_string()])),
                Err(PluginWorkbenchResultError::InvalidView)
            ),
            "{} must be rejected",
            String::from_utf8_lossy(&data)
        );
    }
}

// @Test("multiline drafts accept long prompts and retain a bounded input size")
#[test]
fn long_drafts() {
    fn draft(count: usize) -> Vec<u8> {
        serde_json::to_vec(&serde_json::json!({
            "ui": {"type": "textField", "id": "draft", "multiline": true, "value": "x".repeat(count)}
        }))
        .expect("encodes")
    }
    PluginViewResult::from_json(&draft(32_000), &BTreeSet::new()).expect("bounded draft accepted");
    assert!(matches!(
        PluginViewResult::from_json(&draft(UINode::MAXIMUM_INPUT_BYTES + 1), &BTreeSet::new()),
        Err(PluginWorkbenchResultError::InvalidView)
    ));
}

// @Test("a command returns effects for the host to carry out")
#[test]
fn command_result_is_validated() {
    let result = PluginCommandResult::from_json(
        br#"{"effects": [{"type": "error", "text": "Failed"}]}"#,
        &BTreeSet::new(),
    )
    .expect("command result decodes");
    assert_eq!(result.effects, vec![UIEffect::Error("Failed".to_string())]);
    assert_eq!(
        PluginCommandResult::from_json(b"{}", &BTreeSet::new()).expect("empty result"),
        PluginCommandResult::new()
    );
    for invalid in [
        r#"{"effects": [{"type": "panel", "id": "terminal"}]}"#,
        r#"{"effects": [{"type": "message", "text": ""}]}"#,
        "[]",
    ] {
        assert!(
            matches!(
                PluginCommandResult::from_json(
                    invalid.as_bytes(),
                    &BTreeSet::from(["status".to_string()])
                ),
                Err(PluginWorkbenchResultError::InvalidCommandResult)
            ),
            "{invalid} must be rejected"
        );
    }
}

// @Test("a harness runs an agent's turns, is called with whole turns and never reaches the model")
#[test]
fn harness_is_validated() {
    let valid = decode(
        r#"
        {"cove.ai.harness/v1": [{"id": "careful", "title": "Careful", "entryPoint": "harness"}],
         "cove.ai.agent/v1": [{"id": "careful", "title": "Careful", "harness": "careful"}],
         "cove.ai.tool/v1": [{"entryPoint": "harness", "title": "Harness", "description": "Not a tool."}]}
        "#,
    )
    .expect("valid harness manifest");
    assert_eq!(
        valid
            .contributes
            .decode::<AgentContributionPoint>()
            .expect("decodes agents")
            .first()
            .and_then(|agent| agent.harness.clone()),
        Some("careful".to_string())
    );
    assert!(!valid.exposes_to_ai("harness"));
    let package =
        ValidatedPluginPackage::new(std::path::PathBuf::from("/careful.coveplugin"), valid, None);
    assert!(package.is_host_entry_point("harness"));
    assert!(!package.is_host_entry_point("other"));

    let runtime = contract(
        r#"{"version":1,"entries":[{"name":"harness","title":"harness","description":"","input":{"record":{"turn":"string"}}},{"name":"other","title":"other","description":"","input":{"record":{"text":"string"}}}]}"#,
    );
    AIHarnessContributionPoint::validate_runtime(
        &AIHarnessContribution::new("careful", "Careful", "harness"),
        Some(&runtime),
    )
    .expect("harness valid");
    assert_eq!(
        AIHarnessContributionPoint::validate_runtime(
            &AIHarnessContribution::new("careful", "Careful", "other"),
            Some(&runtime)
        ),
        Err(PluginManifestValidationError::InvalidContribution(
            AIHarnessContributionPoint::ID.to_string()
        ))
    );
    for invalid in [
        r#"{"cove.ai.harness/v1": [{"id": "Careful", "title": "Careful", "entryPoint": "harness"}]}"#,
        r#"{"cove.ai.agent/v1": [{"id": "careful", "title": "Careful", "harness": "Not An Id"}]}"#,
    ] {
        assert!(
            matches!(
                decode(invalid),
                Err(PluginManifestValidationError::InvalidContribution(_))
            ),
            "{invalid} must be rejected"
        );
    }
}

// @Test("events carry the action, the raising control's value and every control value")
#[test]
fn event_encodes() {
    let mut event = UIEvent::new("add");
    event.arguments = Some(PluginJSON::Object(BTreeMap::from([(
        "list".to_string(),
        PluginJSON::String("today".to_string()),
    )])));
    event.value = Some(PluginJSON::String("Ship".to_string()));
    event.values = BTreeMap::from([
        ("draft".to_string(), PluginJSON::String("Ship".to_string())),
        ("done".to_string(), PluginJSON::Bool(true)),
    ]);
    let encoded = serde_json::to_vec(&event).expect("encodes");
    let object: serde_json::Value = serde_json::from_slice(&encoded).expect("object");
    assert_eq!(object["action"], serde_json::json!("add"));
    assert_eq!(object["values"]["done"], serde_json::json!(true));
    assert_eq!(object["arguments"]["list"], serde_json::json!("today"));
}

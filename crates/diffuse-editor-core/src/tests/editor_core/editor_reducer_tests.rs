//! Ported from `Editor/Tests/EditorCoreTests/EditorReducerTests.swift`.

use std::collections::BTreeSet;

use crate::ai::chat::editor_ai_settings::{EditorCapabilityReleasePhase, EditorCapabilitySettings};
use crate::state::editor_reducer::{EditorAction, EditorReducer};
use crate::state::editor_state::{
    EditorConsoleSeverity, EditorPhysicsDebugOverlayOptions, EditorState,
};
use crate::state::workspace::content::EditorContent;

/// Selecting a single entity replaces the selection set.
#[test]
fn selecting_entity_replaces_selection_set() {
    let mut state = EditorState::default();
    state.selection.selected_entity_id = Some(1);
    state.selection.selected_entity_ids = BTreeSet::from([1, 2]);

    EditorReducer::reduce(&mut state, EditorAction::SetSelectedEntity(Some(42)));

    assert_eq!(state.selection.selected_entity_id, Some(42));
    assert_eq!(state.selection.selected_entity_ids, BTreeSet::from([42]));
}

/// Clearing selection empties primary and multi-selection.
#[test]
fn clearing_selection_empties_selection_set() {
    let mut state = EditorState::default();
    state.selection.selected_entity_id = Some(1);
    state.selection.selected_entity_ids = BTreeSet::from([1, 2]);

    EditorReducer::reduce(&mut state, EditorAction::SetSelectedEntity(None));

    assert_eq!(state.selection.selected_entity_id, None);
    assert!(state.selection.selected_entity_ids.is_empty());
}

/// The agent canvas follows the tools it uses and clears with the conversation.
#[test]
fn agent_canvas() {
    assert_eq!(
        EditorContent::touched_by_tool("write_file"),
        Some(EditorContent::Files)
    );
    assert_eq!(
        EditorContent::touched_by_tool("add_media_clip"),
        Some(EditorContent::Timeline)
    );
    assert_eq!(
        EditorContent::touched_by_tool("save_scene"),
        Some(EditorContent::Scene)
    );
    assert_eq!(EditorContent::touched_by_tool("vcs_status"), None);
    let mut state = EditorState::default();
    EditorReducer::reduce(
        &mut state,
        EditorAction::SetAgentCanvas(Some(EditorContent::Files)),
    );
    assert_eq!(state.assistant.agent_canvas, Some(EditorContent::Files));
    EditorReducer::reduce(&mut state, EditorAction::ClearChatHistory);
    assert_eq!(state.assistant.agent_canvas, None);
}

/// Content follows the action.
#[test]
fn setting_content() {
    let mut state = EditorState::default();
    EditorReducer::reduce(
        &mut state,
        EditorAction::SetContent(EditorContent::Timeline),
    );
    assert_eq!(state.content, EditorContent::Timeline);
}

/// Appending console messages assigns stable increasing ids.
#[test]
fn appending_console_messages_assigns_ids() {
    let mut state = EditorState::default();

    EditorReducer::reduce(&mut state, EditorAction::console_message(" First "));
    EditorReducer::reduce(
        &mut state,
        EditorAction::AppendConsoleMessage {
            message: "Second".to_string(),
            severity: EditorConsoleSeverity::Warning,
            detail: None,
            target: None,
            next_step: None,
        },
    );

    let ids: Vec<u64> = state
        .output
        .console_entries
        .iter()
        .map(|entry| entry.id)
        .collect();
    assert_eq!(ids, [1, 2]);
    let messages: Vec<&str> = state
        .output
        .console_entries
        .iter()
        .map(|entry| entry.message.as_str())
        .collect();
    assert_eq!(messages, ["First", "Second"]);
    assert_eq!(
        state
            .output
            .console_entries
            .last()
            .map(|entry| entry.severity),
        Some(EditorConsoleSeverity::Warning)
    );
}

/// Empty console messages are ignored.
#[test]
fn empty_console_messages_are_ignored() {
    let mut state = EditorState::default();

    EditorReducer::reduce(&mut state, EditorAction::console_message("   \n\t"));

    assert!(state.output.console_entries.is_empty());
    assert_eq!(state.output.next_console_entry_id, 1);
}

/// Console history keeps the latest 200 entries.
#[test]
fn console_history_is_bounded() {
    let mut state = EditorState::default();

    for index in 0..205 {
        EditorReducer::reduce(
            &mut state,
            EditorAction::console_message(format!("entry {index}")),
        );
    }

    assert_eq!(state.output.console_entries.len(), 200);
    assert_eq!(
        state
            .output
            .console_entries
            .first()
            .map(|entry| entry.message.as_str()),
        Some("entry 5")
    );
    assert_eq!(
        state
            .output
            .console_entries
            .last()
            .map(|entry| entry.message.as_str()),
        Some("entry 204")
    );
}

/// Capability settings update release gate state.
#[test]
fn capability_settings_update_release_gate_state() {
    let mut state = EditorState::default();

    EditorReducer::reduce(
        &mut state,
        EditorAction::SetCapabilitySettings(EditorCapabilitySettings::new(
            EditorCapabilityReleasePhase::Beta,
        )),
    );

    assert_eq!(
        state.assistant.capability_settings.release_phase,
        EditorCapabilityReleasePhase::Beta
    );
}

/// Physics debug overlay options are bounded to known categories.
#[test]
fn physics_debug_options_are_sanitized() {
    let mut state = EditorState::default();
    state.viewport.physics_debug_overlay_options = EditorPhysicsDebugOverlayOptions::new(0);
    let unknown = EditorPhysicsDebugOverlayOptions::new(0xFF);

    EditorReducer::reduce(
        &mut state,
        EditorAction::SetPhysicsDebugOverlayOptions(unknown),
    );

    assert_eq!(
        state.viewport.physics_debug_overlay_options,
        EditorPhysicsDebugOverlayOptions::all()
    );
}

/// Inspector section batches collapse and expand in one reducer action.
#[test]
fn inspector_section_batch_collapse() {
    let mut state = EditorState::default();
    state.selection.inspector_collapsed_section_ids = BTreeSet::from(["existing".to_string()]);

    EditorReducer::reduce(
        &mut state,
        EditorAction::SetInspectorSectionsCollapsed {
            ids: BTreeSet::from(["general".to_string(), "transform".to_string()]),
            is_collapsed: true,
        },
    );
    assert_eq!(
        state.selection.inspector_collapsed_section_ids,
        BTreeSet::from([
            "existing".to_string(),
            "general".to_string(),
            "transform".to_string()
        ])
    );

    EditorReducer::reduce(
        &mut state,
        EditorAction::SetInspectorSectionsCollapsed {
            ids: BTreeSet::from(["existing".to_string(), "transform".to_string()]),
            is_collapsed: false,
        },
    );
    assert_eq!(
        state.selection.inspector_collapsed_section_ids,
        BTreeSet::from(["general".to_string()])
    );
}

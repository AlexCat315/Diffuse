//! Ported from `Editor/Tests/EditorCoreTests/EditorStoreTests.swift`.

use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;

use diffuse_scene::components::core::value::{ComponentValue, ManifestComponent};
use diffuse_script::core::script_component::{ScriptBinding, ScriptBindingID};
use diffuse_script::interop::component_registry_script_codec::encode_script_binding;

use crate::ai::chat::editor_ai_settings::{EditorCapabilityReleasePhase, EditorCapabilitySettings};
use crate::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use crate::scene::manifest::node::EditorSceneManifestNode;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{
    EditorFrameStats, EditorFrameStatsHistorySample, EditorParticleDiagnosticsSample,
    EditorPhysicsDebugOverlayOptions, EditorPhysicsDebugOverlayScope, EditorState,
};
use crate::state::editor_store::EditorStore;
use crate::state::viewports::editor_viewport_state::EditorViewportState;
use crate::state::workspace::editor_workbench_state::{
    EditorIssueTarget, EditorOperation, EditorOperationKind, EditorScriptNavigationRequest,
};

fn count_notifications(store: &EditorStore) -> Rc<RefCell<u64>> {
    let notifications = Rc::new(RefCell::new(0));
    let counter = notifications.clone();
    let _ = store.subscribe(Rc::new(move |_| {
        *counter.borrow_mut() += 1;
    }));
    notifications
}

/// Workbench navigation and running operations are not replayed from persisted state.
#[test]
fn transient_workbench_state() {
    let store = EditorStore::new();
    store.dispatch(EditorAction::SetOperation(EditorOperation::with_defaults(
        EditorOperationKind::Importing,
        "Importing",
    )));
    store.dispatch(EditorAction::NavigateToScript(
        EditorScriptNavigationRequest::with_position("Player", 3, 6),
    ));
    store.dispatch(EditorAction::SetViewportMode(
        crate::state::workspace::editor_workbench_state::EditorViewportMode::Game,
    ));
    store.dispatch(EditorAction::SetGamePreviewFocused(true));
    store.dispatch(EditorAction::SetGamePreviewResolution(
        crate::state::workspace::editor_workbench_state::EditorGamePreviewResolution::Portrait,
    ));
    let data = serde_json::to_vec(&store.state()).expect("encode");
    let decoded: EditorState = serde_json::from_slice(&data).expect("decode");
    assert!(decoded.navigation.operations.is_empty());
    assert!(decoded.navigation.script_navigation.is_none());
    assert_eq!(
        decoded.viewport.mode,
        crate::state::workspace::editor_workbench_state::EditorViewportMode::Scene
    );
    assert!(!decoded.viewport.game_preview_focused);
    assert_eq!(
        decoded.viewport.game_preview_resolution,
        crate::state::workspace::editor_workbench_state::EditorGamePreviewResolution::Fit
    );
    let defaults: EditorViewportState = serde_json::from_str("{}").expect("defaults");
    assert_eq!(
        defaults.game_preview_resolution,
        crate::state::workspace::editor_workbench_state::EditorGamePreviewResolution::Fit
    );
}

/// Compiler errors retain a clickable source line even without a language service.
#[test]
fn compiler_diagnostic_target() {
    let target = EditorIssueTarget::compiler_diagnostic(
        "Player",
        Path::new("/project/Scripts/Player.swift"),
        "/project/Scripts/Player.swift:19:7: error: cannot find 'missing' in scope\n",
    );
    assert_eq!(
        target,
        EditorIssueTarget::Script {
            id: "Player".to_string(),
            line: 18,
            column: 6
        }
    );
}

/// Unresolved export bindings locate the nested entity that needs repair.
#[test]
fn unresolved_binding_target() {
    let binding =
        ScriptBinding::from_identifier("game.missing", ScriptBindingID::new(), true, "{}");
    let script_value = ComponentValue::Object(std::collections::BTreeMap::from([(
        "bindings".to_string(),
        ComponentValue::Array(vec![ComponentValue::Object(encode_script_binding(
            &binding,
        ))]),
    )]));
    let child = EditorSceneManifestNode::with_options(
        42,
        "Player: Main",
        "empty",
        None,
        vec![ManifestComponent::new("script", script_value)],
        Vec::new(),
    );
    let root =
        EditorSceneManifestNode::with_options(1, "Root", "empty", None, Vec::new(), vec![child]);
    let manifest = EditorSceneManifest::new(0, 2, vec![root]);
    assert_eq!(
        EditorIssueTarget::unresolved_binding_target(
            &["Player: Main: game.missing".to_string()],
            &manifest,
        ),
        Some(EditorIssueTarget::Entity { id: 42 })
    );
    assert_eq!(
        EditorIssueTarget::unresolved_binding_target(
            &["Unknown: game.missing".to_string()],
            &manifest,
        ),
        None
    );
}

/// No-op actions do not notify subscribers.
#[test]
fn no_op_actions_do_not_notify_subscribers() {
    let mut state = EditorState::default();
    state.timing.connected = true;
    let store = EditorStore::with_state(state);
    let notifications = count_notifications(&store);

    store.dispatch(EditorAction::SetConnected(true));

    assert_eq!(store.version(), 0);
    assert_eq!(*notifications.borrow(), 0);
}

/// Changed actions increment version and notify subscribers.
#[test]
fn changed_actions_notify_subscribers() {
    let store = EditorStore::new();
    let notifications = count_notifications(&store);

    store.dispatch(EditorAction::SetConnected(true));

    assert_eq!(store.version(), 1);
    assert_eq!(*notifications.borrow(), 1);
    assert!(store.connected());
}

/// Recovered autosaves stay dirty until an explicit save.
#[test]
fn recovered_autosave_dirty_state() {
    let mut state = EditorState::default();
    state.document.scene_revision = 12;
    state.document.last_saved_scene_revision = 12;
    let store = EditorStore::with_state(state);
    assert!(!store.scene_dirty());

    store.dispatch(EditorAction::SetSceneRecoveryPending(true));
    assert!(store.scene_dirty());
    assert!(store.scene_recovery_pending());

    store.dispatch(EditorAction::MarkSceneSaved(12));
    assert!(!store.scene_dirty());
    assert!(!store.scene_recovery_pending());
}

/// Console changes notify subscribers.
#[test]
fn console_changes_notify_subscribers() {
    let store = EditorStore::new();
    let notifications = count_notifications(&store);

    store.dispatch(EditorAction::console_message("Built project"));

    assert_eq!(store.version(), 1);
    assert_eq!(*notifications.borrow(), 1);
    assert_eq!(
        store.latest_console_entry().map(|entry| entry.message),
        Some("Built project".to_string())
    );
}

/// Selection primary modifier behavior decodes grouped state.
#[test]
fn primary_modifier_behavior_decodes_grouped_state() {
    let state: EditorState =
        serde_json::from_str(r#"{"selection":{"primarySelectBehavior":"toggle"}}"#)
            .expect("decode");
    assert_eq!(
        state.selection.primary_select_behavior,
        crate::state::editor_state::SelectionPrimaryModifierBehavior::Toggle
    );
}

/// Selection primary modifier behavior encodes platform-neutral key.
#[test]
fn primary_modifier_behavior_encodes_platform_neutral_key() {
    let mut state = EditorState::default();
    state.selection.primary_select_behavior =
        crate::state::editor_state::SelectionPrimaryModifierBehavior::Toggle;

    let json = serde_json::to_string(&state).expect("encode");
    assert!(json.contains(r#""primarySelectBehavior":"toggle""#));
    assert!(!json.contains("cmdSelectBehavior"));
}

/// Unspecified editor groups use their own defaults.
#[test]
fn unspecified_groups_use_defaults() {
    let state: EditorState =
        serde_json::from_str(r#"{"timing":{"connected":true}}"#).expect("decode");
    assert_eq!(
        state.assistant.capability_settings,
        EditorCapabilitySettings::with_defaults()
    );
    assert!(state.viewport.physics_debug_overlay_options.raw_value == 0);
    assert_eq!(
        state.viewport.physics_debug_overlay_scope,
        EditorPhysicsDebugOverlayScope::Selected
    );
}

/// Physics debug overlay options and scope persist and notify subscribers.
#[test]
fn physics_debug_options_persist_and_notify() {
    let store = EditorStore::new();
    let notifications = count_notifications(&store);
    let options = EditorPhysicsDebugOverlayOptions::new(
        EditorPhysicsDebugOverlayOptions::SHAPES.raw_value
            | EditorPhysicsDebugOverlayOptions::JOINTS.raw_value,
    );

    store.dispatch(EditorAction::SetPhysicsDebugOverlayOptions(options));
    store.dispatch(EditorAction::SetPhysicsDebugOverlayScope(
        EditorPhysicsDebugOverlayScope::Scene,
    ));

    assert_eq!(store.physics_debug_overlay_options(), options);
    assert_eq!(
        store.physics_debug_overlay_scope(),
        EditorPhysicsDebugOverlayScope::Scene
    );
    assert_eq!(*notifications.borrow(), 2);
    let data = serde_json::to_vec(&store.state()).expect("encode");
    let restored: EditorState = serde_json::from_slice(&data).expect("decode");
    assert_eq!(restored.viewport.physics_debug_overlay_options, options);
    assert_eq!(
        restored.viewport.physics_debug_overlay_scope,
        EditorPhysicsDebugOverlayScope::Scene
    );
}

/// Capability settings notify subscribers.
#[test]
fn capability_settings_notify_subscribers() {
    let store = EditorStore::new();
    let notifications = count_notifications(&store);

    store.dispatch(EditorAction::SetCapabilitySettings(
        EditorCapabilitySettings::new(EditorCapabilityReleasePhase::Experimental),
    ));

    assert_eq!(store.version(), 1);
    assert_eq!(*notifications.borrow(), 1);
    assert_eq!(
        store.capability_settings().release_phase,
        EditorCapabilityReleasePhase::Experimental
    );
}

/// Frame stats separate tick gap from actual frame work.
#[test]
fn frame_stats_separate_tick_gap_from_work() {
    let stats = EditorFrameStats::new(
        0.410, 0.0, 0.00069, 0.0, 0.00862, 0.00862, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    );

    assert!((stats.frame_ms - 410.0).abs() < 0.001);
    assert!((stats.work_ms() - 17.93).abs() < 0.001);
    assert!((stats.pacing_gap_ms() - 392.07).abs() < 0.001);
    assert!(stats.is_frame_pacing_dominated());
    assert!(stats.fps < 3.0);
    assert!(stats.work_fps() > 55.0);
}

/// Frame stats updates maintain a bounded diagnostic history.
#[test]
fn frame_stats_history_is_bounded() {
    let store = EditorStore::new();
    let notifications = count_notifications(&store);

    let sample_count = EditorState::MAX_FRAME_STATS_HISTORY_SAMPLES + 5;
    for index in 1..=sample_count {
        store.dispatch(EditorAction::TickFrame(index as u64));
        let mut stats = EditorFrameStats::with_defaults();
        stats.frame_seconds = index as f64 / 1_000.0;
        stats.fps = if stats.frame_seconds > 0.0 {
            1.0 / stats.frame_seconds
        } else {
            0.0
        };
        stats.frame_ms = stats.frame_seconds * 1000.0;
        stats.draw_call_count = index as i64;
        store.dispatch(EditorAction::UpdateFrameStats(stats));
    }

    let history = store.frame_stats_history();
    assert_eq!(history.len(), EditorState::MAX_FRAME_STATS_HISTORY_SAMPLES);
    assert_eq!(history.first().map(|sample| sample.sample_index), Some(6));
    assert_eq!(history.first().map(|sample| sample.frame_index), Some(6));
    assert_eq!(
        history.last().map(|sample| sample.sample_index),
        Some(sample_count as u64)
    );
    assert_eq!(
        history.last().map(|sample| sample.frame_index),
        Some(sample_count as u64)
    );
    assert_eq!(
        history.last().map(|sample| sample.stats.draw_call_count),
        Some(sample_count as i64)
    );
    assert_eq!(*notifications.borrow(), sample_count as u64);
}

/// Frame stats history is transient editor state.
#[test]
fn frame_stats_history_is_transient() {
    let mut state = EditorState::default();
    state.timing.frame_stats_history = vec![EditorFrameStatsHistorySample::new(
        1,
        10,
        EditorFrameStats::with_defaults(),
    )];

    let data = serde_json::to_vec(&state).expect("encode");
    let json = String::from_utf8(data.clone()).expect("utf8");
    let decoded: EditorState = serde_json::from_slice(&data).expect("decode");
    assert!(!json.contains("frameStatsHistory"));
    assert!(decoded.timing.frame_stats_history.is_empty());
}

/// Particle diagnostics maintain a bounded transient history.
#[test]
fn particle_diagnostics_history_is_bounded_and_transient() {
    let store = EditorStore::new();
    let notifications = count_notifications(&store);

    let sample_count = EditorState::MAX_PARTICLE_DIAGNOSTICS_HISTORY_SAMPLES + 3;
    for index in 1..=sample_count {
        store.dispatch(EditorAction::TickFrame(index as u64));
        store.dispatch(EditorAction::UpdateParticleDiagnostics(
            EditorParticleDiagnosticsSample::new(
                index as u64,
                index as u64,
                1.0 / 60.0,
                1,
                1,
                index as i64,
                1_000,
                index as i64,
                index as i64,
                0,
                0,
                0,
                index as i64,
                0,
                0,
                0,
                0,
                index as i64,
                0,
                1,
                0,
                0,
                0,
                0,
                0,
            ),
        ));
    }

    let history = store.particle_diagnostics_history();
    assert_eq!(
        history.len(),
        EditorState::MAX_PARTICLE_DIAGNOSTICS_HISTORY_SAMPLES
    );
    assert_eq!(history.first().map(|sample| sample.sample_index), Some(4));
    assert_eq!(history.first().map(|sample| sample.frame_index), Some(4));
    assert_eq!(
        history.last().map(|sample| sample.sample_index),
        Some(sample_count as u64)
    );
    assert_eq!(
        history.last().map(|sample| sample.live_particle_count),
        Some(sample_count as i64)
    );
    assert_eq!(*notifications.borrow(), sample_count as u64);

    let data = serde_json::to_vec(&store.state()).expect("encode");
    let json = String::from_utf8(data.clone()).expect("utf8");
    let decoded: EditorState = serde_json::from_slice(&data).expect("decode");
    assert!(!json.contains("particleDiagnosticsHistory"));
    assert!(decoded.timing.particle_diagnostics_history.is_empty());
}

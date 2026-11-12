//! Ported from `Editor/Tests/EditorCoreTests/EditorAgentTaskTests.swift`.

use std::collections::{BTreeMap, BTreeSet};

use diffuse_capability::capability_contract::{CapabilityExposurePolicy, ReleasePhase};
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_plugin::Uuid;

use crate::ai::chat::editor_agent_task_service::{
    EditorAgentTask, EditorAgentTaskPhase, EditorAgentTaskService, EditorAgentTaskTarget,
};
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::EditorState;
use crate::state::editor_store::EditorStore;
use crate::state::workspace::content::EditorContent;

/// Each content offers its own tools.
#[test]
fn functional_profiles() {
    let scene = EditorContent::Scene.profile();
    let files = EditorContent::Files.profile();
    let timeline = EditorContent::Timeline.profile();
    assert!(scene.capability_ids().contains("scene.set_material"));
    assert!(scene.capability_ids().contains("scene.set_script_bindings"));
    assert!(scene.capability_ids().contains("scene.set_rigid_body_mass"));
    assert!(scene.project_tool_names().contains("export_project"));
    assert!(files.capability_ids().is_empty());
    assert!(files.project_tool_names().is_superset(&BTreeSet::from([
        "write_file".to_string(),
        "compile_scripts".to_string()
    ])));
    assert!(!files.project_tool_names().contains("save_scene"));
    assert!(timeline.project_tool_names().contains("export_media"));
    assert!(!timeline.project_tool_names().contains("compile_scripts"));
}

/// Capability discovery cannot widen a workflow allow-list.
#[test]
fn capability_discovery() {
    let profile = EditorContent::Scene.profile();
    let allowed: BTreeSet<String> = profile
        .capability_ids()
        .difference(&BTreeSet::from([
            "scene.set_script_bindings".to_string(),
            "scene.set_script_property".to_string(),
        ]))
        .cloned()
        .collect();
    let mut policy = CapabilityExposurePolicy::new(ReleasePhase::Stable);
    policy.allowed_domains = Some(BTreeSet::from(["scene".to_string()]));
    policy.allowed_capability_ids = Some(allowed.clone());
    policy.maximum_capabilities = 100;
    let registry = CapabilityRegistry::default_registry();
    let snapshot = registry.exposure_snapshot(
        &policy,
        None,
        0,
        &Vec::new(),
        Some(&allowed),
        &BTreeMap::new(),
    );
    assert!(snapshot.contract("scene.set_material").is_some());
    assert!(snapshot.contract("scene.set_script_bindings").is_none());
    // Shared inspector descriptions may match "script"; write access stays scoped.
    assert!(
        registry
            .search_contracts("script", &policy, &BTreeMap::new(), 100)
            .iter()
            .all(|contract| contract.access
                == diffuse_capability::capability_contract::CapabilityAccess::Read)
    );
    assert!(
        snapshot
            .contracts
            .iter()
            .all(|contract| allowed.contains(&contract.id))
    );
}

/// A task keeps its target through selection and workspace changes, and rejects
/// replaced documents.
#[test]
fn frozen_target_and_lifecycle() {
    let mut service = EditorAgentTaskService::new();
    let store = EditorStore::new();
    store.dispatch(EditorAction::SetSceneRevision(7));
    store.dispatch(EditorAction::SetSelectedEntity(Some(42)));
    let target = EditorAgentTaskTarget::new(
        store.state().document.identity,
        7,
        EditorContent::Scene,
        BTreeSet::from([42]),
        Some(42),
    );
    let task = service
        .begin("Set material", target.clone())
        .expect("first task");
    assert!(service.begin("Another task", target.clone()).is_none());
    store.dispatch(EditorAction::SetSelectedEntity(Some(99)));
    store.dispatch(EditorAction::SetContent(EditorContent::Files));
    assert_eq!(
        service.active_task().map(|task| task.target.clone()),
        Some(target.clone())
    );
    service.transition(EditorAgentTaskPhase::AwaitingReview, "Change material");
    assert_eq!(service.active_task_id(), Some(&task.id));
    assert!(target.matches(&store.state().document.identity, store.scene_revision()));
    store.dispatch(EditorAction::BeginSceneDocument);
    assert!(!target.matches(&store.state().document.identity, 7));
    service.transition(EditorAgentTaskPhase::Discarded, "");
    assert!(service.active_task().is_none());
    assert_eq!(
        service.tasks().first().map(|task| task.phase),
        Some(EditorAgentTaskPhase::Discarded)
    );
    assert!(service.begin("New task", target).is_some());
}

/// Content, task sessions and document identity do not persist.
#[test]
fn session_persistence_boundary() {
    let mut state = EditorState {
        content: EditorContent::Timeline,
        ..EditorState::default()
    };
    let identity = state.document.identity.clone();
    let target = EditorAgentTaskTarget::new(
        identity.clone(),
        0,
        EditorContent::Timeline,
        BTreeSet::new(),
        None,
    );
    state.assistant.agent_tasks = vec![EditorAgentTask::with_default_id("Animate", target)];
    let data = serde_json::to_vec(&state).expect("encode");
    let restored: EditorState = serde_json::from_slice(&data).expect("decode");
    assert_eq!(restored.content, EditorContent::Scene);
    assert!(restored.assistant.agent_tasks.is_empty());
    assert_ne!(restored.document.identity, identity);
}

/// Task cancellation and terminal results release the active slot.
#[test]
fn cancellation() {
    for phase in [
        EditorAgentTaskPhase::Cancelled,
        EditorAgentTaskPhase::Failed,
        EditorAgentTaskPhase::Conflict,
        EditorAgentTaskPhase::Applied,
        EditorAgentTaskPhase::Completed,
    ] {
        let mut service = EditorAgentTaskService::new();
        let target =
            EditorAgentTaskTarget::new(Uuid::new(), 1, EditorContent::Scene, BTreeSet::new(), None);
        let _ = service.begin("Task", target.clone());
        service.transition(phase, "Result");
        assert!(service.active_task_id().is_none(), "{phase:?}");
        assert_eq!(
            service.tasks().first().map(|task| task.summary.as_str()),
            Some("Result")
        );
        assert!(service.begin("Next", target).is_some(), "{phase:?}");
    }
}

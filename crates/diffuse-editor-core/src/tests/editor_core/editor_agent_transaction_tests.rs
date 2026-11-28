//! `Editor/Tests/EditorCoreTests/EditorAgentTransactionTests.swift`.
//!
//! Agent plans commit through the manual undo history, keep the selection they
//! were captured with, and cannot apply over a scene the user changed while the
//! review was open. Replacing the document cancels pending tasks.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;
use std::rc::Rc;

use diffuse_ai::planning::proposal::Proposal;
use diffuse_ai::planning::scene_edit_plan::SceneEditPlan;
use diffuse_ai::planning::scene_edit_plan_executor::SceneEditPlanExecutor;
use diffuse_intent::planning::intent_ir::IntentSource;
use diffuse_intent::transactions::transaction_ir::TransactionApprovalPolicy;
use diffuse_intent::pipeline::commit_pipeline::CommitEntry;

use crate::ai::chat::editor_agent_task_service::{EditorAgentTaskPhase, EditorAgentTaskTarget};
use crate::application::editor_application::{EditorApplication, EditorApplicationOptions};
use crate::state::editor_reducer::EditorAction;
use crate::state::workspace::content::EditorContent;

fn directory() -> PathBuf {
    let path = std::env::temp_dir().join(diffuse_kernel::codable::new_uuid());
    fs::create_dir_all(&path).expect("project directory");
    path
}

fn launch(path: &PathBuf) -> Rc<EditorApplication> {
    EditorApplication::with_options(
        path.to_string_lossy().into_owned(),
        EditorApplicationOptions {
            seed_preview_scene: true,
            ..EditorApplicationOptions::default()
        },
    )
    .expect("launch editor")
}

/// Swift's `plan(entityID:)`.
fn plan(entity_id: u64) -> SceneEditPlan {
    let json = serde_json::json!({
        "summary": "Rename task target",
        "steps": [
            {"op": "set_name", "entity_id": format!("scene:{entity_id}"), "name": "Agent Target"}
        ]
    });
    serde_json::from_value(json).expect("decode plan")
}

fn begin(app: &Rc<EditorApplication>, entity_id: u64, plan: &SceneEditPlan) {
    let target = EditorAgentTaskTarget {
        document_id: app.store.state().document.identity,
        scene_revision: app.store.scene_revision(),
        content: EditorContent::Scene,
        selected_entity_ids: BTreeSet::from([entity_id]),
        primary_entity_id: Some(entity_id),
    };
    assert!(
        app
            .agent_task_service
            .borrow_mut()
            .begin("Rename target", target)
            .is_some()
    );
    app.agent_execution.borrow_mut().proposal = Some(Proposal::new(
        "fixture".to_string(),
        "Rename target".to_string(),
        plan.clone(),
    ));
}

#[test]
fn agent_changes_share_the_manual_history_and_captured_selection() {
    let path = directory();
    let app = launch(&path);
    let entity_id = app.scene.default_selection_id().expect("default selection");
    let original = app
        .scene
        .entity_summary(Some(entity_id))
        .expect("entity summary")
        .name;
    let plan = plan(entity_id);
    begin(&app, entity_id, &plan);

    app.store.dispatch(EditorAction::SetSelectedEntity(None));
    app.store.dispatch(EditorAction::SetContent(EditorContent::Files));
    let context = app.make_capability_invocation_context(IntentSource::Ai, 1.0, Vec::new());
    assert_eq!(context.selected_entity_id, Some(entity_id));

    let transaction = SceneEditPlanExecutor::new()
        .build_transaction_with_defaults(&plan, &app.scene.scene())
        .expect("build transaction");
    assert!(
        app.run_plan_transaction(&transaction, Some(context), CommitEntry::Ui)
            .is_ok()
    );
    if app.store.pending_confirmation_request().is_some() {
        app.accept_pending_confirmation();
    }
    assert_eq!(
        app.agent_task_service.borrow().tasks()[0].phase,
        EditorAgentTaskPhase::Applied
    );
    assert_eq!(
        app.scene
            .entity_summary(Some(entity_id))
            .expect("entity summary")
            .name,
        "Agent Target"
    );
    assert!(app.can_undo());
    app.undo();
    assert_eq!(
        app.scene
            .entity_summary(Some(entity_id))
            .expect("entity summary")
            .name,
        original
    );

    app.shutdown();
    let _ = fs::remove_dir_all(&path);
}

#[test]
fn review_rejects_a_changed_scene_and_document_replacement_cancels_tasks() {
    let path = directory();
    let app = launch(&path);
    let entity_id = app.scene.default_selection_id().expect("default selection");
    let plan = plan(entity_id);
    begin(&app, entity_id, &plan);

    let transaction = SceneEditPlanExecutor::new()
        .build_transaction(
            &plan,
            &app.scene.scene(),
            None,
            TransactionApprovalPolicy::RequiresApproval,
            None,
            &diffuse_intent::capabilities::built_in_typed_capabilities::BuiltInTypedCapabilityCatalog::registry(),
        )
        .expect("build transaction");
    assert!(
        app.run_plan_transaction(
            &transaction,
            Some(app.make_capability_invocation_context(IntentSource::Ai, 1.0, Vec::new())),
            CommitEntry::Ui,
        )
        .is_ok()
    );
    assert_eq!(
        app.agent_task_service.borrow().tasks()[0].phase,
        EditorAgentTaskPhase::AwaitingReview
    );
    assert!(app.scene.rename_entity(entity_id, "Manual Change"));
    app.accept_pending_confirmation();
    assert_eq!(
        app.scene
            .entity_summary(Some(entity_id))
            .expect("entity summary")
            .name,
        "Manual Change"
    );
    assert!(app.store.pending_confirmation_request().is_some());
    assert!(
        app.store
            .ai_status_message()
            .is_some_and(|message| message.contains("scene changed"))
    );
    app.skip_pending_confirmation();
    assert_eq!(
        app.agent_task_service.borrow().tasks()[0].phase,
        EditorAgentTaskPhase::Discarded
    );
    assert!(app.store.pending_confirmation_request().is_none());

    begin(&app, entity_id, &plan);
    let identity = app.store.state().document.identity;
    app.create_empty_scene();
    assert_eq!(
        app.agent_task_service.borrow().tasks()[0].phase,
        EditorAgentTaskPhase::Cancelled
    );
    assert_ne!(app.store.state().document.identity, identity);
    assert!(app.agent_task_service.borrow().active_task().is_none());

    app.shutdown();
    let _ = fs::remove_dir_all(&path);
}

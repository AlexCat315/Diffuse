//! `Editor/Sources/EditorCore/Application/Projects/ProjectLifecycle.swift`.

use std::path::Path;
use std::rc::Rc;

use diffuse_intent::invocation::capability_invocation::{
    ConfirmationAnswer, ConfirmationAnswerOutcome, ConfirmationResolution,
};
use diffuse_intent::transactions::transaction_executor::TransactionExecutionContext;

use crate::application::editor_application::EditorApplication;
use crate::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{
    EditorConsoleSeverity, EditorPendingCloseRequest, EditorPendingDocumentAction, PlaybackState,
};

impl EditorApplication {
    pub(crate) fn begin_scene_document(&self) {
        if let Some(request) = self.intent_coordinator.pending_confirmation_request() {
            let answers = request
                .questions
                .into_iter()
                .map(|question| {
                    let mut answer =
                        ConfirmationAnswer::new(question.id, ConfirmationAnswerOutcome::Skipped);
                    answer.picked_option_id = question
                        .options
                        .into_iter()
                        .find(|option| {
                            matches!(
                                option.id.to_ascii_lowercase().as_str(),
                                "skip" | "discard" | "reject" | "deny" | "cancel"
                            )
                        })
                        .map(|option| option.id);
                    answer
                })
                .collect();
            let mut resolution = ConfirmationResolution::new(
                request.batch_id,
                request.correlation_id,
                answers,
                false,
            );
            resolution.user_id = Some("local-editor".into());
            let mut context = TransactionExecutionContext {
                observation_bus: Some(self.observation_bus.clone()),
                ..TransactionExecutionContext::default()
            };
            if let Err(error) = self
                .intent_coordinator
                .resolve_plan_confirmation(&resolution, &mut context)
            {
                // A cold-log failure must not leave a staged edit targeting the previous scene.
                context.observation_bus = None;
                let _ = self
                    .intent_coordinator
                    .resolve_plan_confirmation(&resolution, &mut context);
                self.store.dispatch(EditorAction::AppendConsoleMessage {
                    message: "Failed to record the skipped scene confirmation".into(),
                    severity: EditorConsoleSeverity::Warning,
                    detail: Some(error.to_string()),
                    target: None,
                    next_step: None,
                });
            }
        }
        // Swift's `beginAgentSceneDocument()` bookkeeping: a replacement
        // document invalidates the active request, its proposal and any
        // captured review target set before the new revision is published.
        if self.agent_task_service.borrow().active_task().is_some() {
            self.update_agent_task(
                crate::ai::chat::editor_agent_task_service::EditorAgentTaskPhase::Cancelled,
                "Task cancelled",
            );
        }
        {
            let mut execution = self.agent_execution.borrow_mut();
            execution.assistant_message_id = None;
            execution.confirmation_target_entity_ids.clear();
            execution.proposal = None;
            execution.request_id = None;
            execution.request_task.take();
        }
        self.store
            .dispatch(EditorAction::SetPendingConfirmationRequest(None));
        self.store.dispatch(EditorAction::BeginSceneDocument);
    }

    pub fn reset_preview_scene(&self) {
        self.leave_geometry_editing();
        self.begin_scene_document();
        self.scene_persistence().remove_editor_autosave();
        self.scene.reset_to_preview_scene();
        self.reload_scripts_after_scene_replacement();
        self.store.dispatch(EditorAction::SetSelectedEntity(
            self.scene.default_selection_id(),
        ));
        self.refresh_scene_world_view();
        self.store
            .dispatch(EditorAction::console_message("Created new preview scene"));
        self.request_display_refresh();
    }

    /// A new document begins empty. Preview fixtures are created explicitly.
    pub fn create_empty_scene(&self) {
        self.leave_geometry_editing();
        self.begin_scene_document();
        self.scene_persistence().remove_editor_autosave();
        self.scene.load(&EditorSceneManifest::new(0, 0, Vec::new()));
        self.reload_scripts_after_scene_replacement();
        self.store.dispatch(EditorAction::SetSelectedEntity(None));
        self.store.dispatch(EditorAction::MarkSceneUnsaved);
        self.refresh_scene_world_view();
        self.store
            .dispatch(EditorAction::console_message("Created new empty scene"));
        self.request_display_refresh();
    }

    pub fn set_close_project_handler(&self, handler: Option<Rc<dyn Fn()>>) {
        self.close_project_handler.replace(handler);
    }

    pub fn request_close_project(&self) {
        if self.store.playback_state() != PlaybackState::Stopped {
            self.apply_playback_state(PlaybackState::Stopped);
        }
        if self.has_unsaved_scene_changes() || self.workstation.has_unsaved_changes() {
            self.store
                .dispatch(EditorAction::RequestClose(EditorPendingCloseRequest::new(
                    EditorPendingDocumentAction::CloseProject,
                )));
        } else {
            self.close_project();
        }
    }

    pub fn close_project(&self) {
        let handler = self.close_project_handler.borrow().clone();
        if let Some(handler) = handler {
            handler();
        }
    }

    pub fn request_new_scene(&self) {
        if self.store.playback_state() != PlaybackState::Stopped {
            self.report_scene_authoring_unavailable("Stop simulation before creating a new scene.");
        } else if self.has_unsaved_scene_changes() {
            self.store
                .dispatch(EditorAction::RequestClose(EditorPendingCloseRequest::new(
                    EditorPendingDocumentAction::NewScene,
                )));
        } else {
            self.create_empty_scene();
        }
    }

    pub fn request_open_scene_manifest(&self) {
        self.request_open_scene(None);
    }

    pub fn request_open_scene_manifest_at(&self, path: &Path) {
        self.request_open_scene(Some(path));
    }

    fn request_open_scene(&self, path: Option<&Path>) {
        if self.store.playback_state() != PlaybackState::Stopped {
            self.report_scene_authoring_unavailable(
                "Stop simulation before opening another scene.",
            );
        } else if self.has_unsaved_scene_changes() {
            self.store.dispatch(EditorAction::RequestClose(
                EditorPendingCloseRequest::with_options(
                    EditorPendingDocumentAction::OpenScene,
                    None,
                    path.map(|path| path.to_string_lossy().into_owned()),
                ),
            ));
        } else if let Some(path) = path {
            self.open_scene_manifest_at(path);
        } else {
            self.open_scene_manifest();
        }
    }
}

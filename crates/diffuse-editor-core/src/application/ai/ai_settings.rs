//! `Editor/Sources/EditorCore/Application/AI/AISettings.swift` (selected helpers).
//!
//! The rest of AISettings.swift (`applyAISettings`, `makeSession`,
//! `workflowContext`, credential plumbing, `clearAIKey`) is ported with the
//! agent-session wiring that constructs and swaps the `Session`.

use crate::ai::chat::editor_agent_task_service::EditorAgentTaskPhase;
use crate::application::editor_application::EditorApplication;
use crate::state::editor_state::PlaybackState;

impl EditorApplication {
    /// `isSceneAuthoringEnabled` — authoring is permitted only when the
    /// simulation is stopped and the scene allows authoring.
    pub fn is_scene_authoring_enabled(&self) -> bool {
        self.store.playback_state() == PlaybackState::Stopped && self.scene.is_authoring_enabled()
    }

    /// `hasStoredAIKey()` — true when the active provider either needs no secret
    /// or a credential is present (checked via the provider's secret auth field's
    /// environment variable).
    pub fn has_stored_ai_key(&self) -> bool {
        let provider_id = self.store.ai_settings().provider_id;
        let catalog = self.ai_provider_catalog();
        let provider = match catalog.provider(&provider_id) {
            Some(provider) => provider,
            None => return false,
        };
        let field = match provider.secret_field() {
            Some(field) => field,
            None => return true,
        };
        match field.environment_variable {
            Some(ref variable) => std::env::var(variable)
                .map(|value| !value.is_empty())
                .unwrap_or(false),
            None => false,
        }
    }

    /// `cancelActiveAIRequest()` — cancels the active session run and records the
    /// task as completed.
    pub(crate) fn cancel_active_ai_request(&self) {
        self.skip_pending_confirmation();
        if let Some(session) = self.session.borrow().as_ref() {
            session.cancel_active_run();
        }
        self.update_agent_task(EditorAgentTaskPhase::Completed, "Cancelled.");
    }
}

//! `Editor/Sources/EditorCore/Application/AI/AISettings.swift` (selected helpers).
//!
//! The rest of AISettings.swift (`applyAISettings`, `makeSession`,
//! `workflowContext`, credential plumbing, `clearAIKey`) is ported with the
//! agent-session wiring that constructs and swaps the `Session`.

use crate::application::editor_application::EditorApplication;
use crate::state::editor_state::PlaybackState;

impl EditorApplication {
    /// `isSceneAuthoringEnabled` — authoring is permitted only when the
    /// simulation is stopped and the scene allows authoring.
    pub fn is_scene_authoring_enabled(&self) -> bool {
        self.store.playback_state() == PlaybackState::Stopped && self.scene.is_authoring_enabled()
    }
}

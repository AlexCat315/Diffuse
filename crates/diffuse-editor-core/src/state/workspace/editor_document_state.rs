//! `Editor/Sources/EditorCore/State/Workspace/EditorDocumentState.swift`.

use diffuse_plugin::Uuid;
use serde::{Deserialize, Serialize};

use crate::state::editor_state::EditorPendingCloseRequest;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorDocumentState {
    /// Transient identity: replacing a document invalidates outstanding task targets.
    #[serde(skip)]
    pub identity: Uuid,
    pub scene_revision: u64,
    #[serde(skip)]
    pub last_saved_scene_revision: u64,
    #[serde(skip)]
    pub scene_recovery_pending: bool,
    #[serde(skip)]
    pub pending_close_request: Option<EditorPendingCloseRequest>,
}

impl EditorDocumentState {
    /// Swift's `init(_ configure:)` without a configuration closure.
    pub fn new() -> Self {
        EditorDocumentState::default()
    }

    /// Swift's `init(_ configure:)` with the closure applied.
    pub fn with_configure(configure: impl FnOnce(&mut EditorDocumentState)) -> Self {
        let mut state = EditorDocumentState::default();
        configure(&mut state);
        state
    }
}

impl Default for EditorDocumentState {
    fn default() -> Self {
        EditorDocumentState {
            identity: Uuid::new(),
            scene_revision: 0,
            last_saved_scene_revision: 0,
            scene_recovery_pending: false,
            pending_close_request: None,
        }
    }
}

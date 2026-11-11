//! `Editor/Sources/EditorCore/State/Viewports/EditorNavigationState.swift`.

use cove_ui_compose::primitives::text::TextBuffer;
use serde::{Deserialize, Serialize};

use crate::state::editor_state::EditorAssetDragPayload;
use crate::state::workspace::editor_workbench_state::{
    EditorOperation, EditorScriptNavigationRequest,
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorNavigationState {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub active_asset_drag: Option<EditorAssetDragPayload>,
    /// Transient navigation and command-palette state.
    #[serde(skip)]
    pub command_palette_visible: bool,
    #[serde(skip)]
    pub operations: Vec<EditorOperation>,
    #[serde(skip)]
    pub script_navigation: Option<EditorScriptNavigationRequest>,
    #[serde(skip)]
    pub asset_navigation_id: Option<String>,
    #[serde(skip)]
    pub asset_navigation_revision: u64,
    #[serde(skip)]
    pub command_palette_query: TextBuffer,
}

impl EditorNavigationState {
    /// Swift's `init(_ configure:)` without a configuration closure.
    pub fn new() -> Self {
        EditorNavigationState::default()
    }

    /// Swift's `init(_ configure:)` with the closure applied.
    pub fn with_configure(configure: impl FnOnce(&mut EditorNavigationState)) -> Self {
        let mut state = EditorNavigationState::default();
        configure(&mut state);
        state
    }
}

impl Default for EditorNavigationState {
    fn default() -> Self {
        EditorNavigationState {
            active_asset_drag: None,
            command_palette_visible: false,
            operations: Vec::new(),
            script_navigation: None,
            asset_navigation_id: None,
            asset_navigation_revision: 0,
            command_palette_query: TextBuffer::default(),
        }
    }
}

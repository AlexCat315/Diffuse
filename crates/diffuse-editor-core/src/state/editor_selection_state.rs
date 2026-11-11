//! `Editor/Sources/EditorCore/State/EditorSelectionState.swift`.

use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};

use crate::state::editor_state::SelectionPrimaryModifierBehavior;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorSelectionState {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub selected_entity_id: Option<u64>,
    #[serde(rename = "selectedEntityIDs")]
    pub selected_entity_ids: BTreeSet<u64>,
    pub primary_select_behavior: SelectionPrimaryModifierBehavior,
    #[serde(rename = "inspectorCollapsedSectionIDs")]
    pub inspector_collapsed_section_ids: BTreeSet<String>,
    /// Session state; older files do not carry it.
    #[serde(skip)]
    pub inspector_scene_settings_visible: bool,
}

impl EditorSelectionState {
    /// Swift's `init(_ configure:)` without a configuration closure.
    pub fn new() -> Self {
        EditorSelectionState::default()
    }

    /// Swift's `init(_ configure:)` with the closure applied.
    pub fn with_configure(configure: impl FnOnce(&mut EditorSelectionState)) -> Self {
        let mut state = EditorSelectionState::default();
        configure(&mut state);
        state
    }
}

impl Default for EditorSelectionState {
    fn default() -> Self {
        EditorSelectionState {
            selected_entity_id: None,
            selected_entity_ids: BTreeSet::new(),
            primary_select_behavior: SelectionPrimaryModifierBehavior::Subtract,
            inspector_collapsed_section_ids: BTreeSet::new(),
            inspector_scene_settings_visible: false,
        }
    }
}

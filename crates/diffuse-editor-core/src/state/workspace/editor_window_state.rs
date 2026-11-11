//! `Editor/Sources/EditorCore/State/Workspace/EditorWindowState.swift`.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorWindowState {
    pub focused: bool,
    pub minimized: bool,
    pub occluded: bool,
}

impl EditorWindowState {
    /// Swift's `init(_ configure:)` without a configuration closure.
    pub fn new() -> Self {
        EditorWindowState::default()
    }

    /// Swift's `init(_ configure:)` with the closure applied.
    pub fn with_configure(configure: impl FnOnce(&mut EditorWindowState)) -> Self {
        let mut state = EditorWindowState::default();
        configure(&mut state);
        state
    }
}

impl Default for EditorWindowState {
    fn default() -> Self {
        EditorWindowState {
            focused: true,
            minimized: false,
            occluded: false,
        }
    }
}

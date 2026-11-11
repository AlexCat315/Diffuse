//! `Editor/Sources/EditorCore/State/Assistant/EditorOutputState.swift`.
//!
//! Console records are transient; the persisted state carries an empty object.

use serde::de::IgnoredAny;
use serde::ser::SerializeStruct;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::state::editor_state::EditorConsoleEntry;
use crate::state::workspace::editor_workbench_state::EditorOutputTab;

#[derive(Clone, Debug, PartialEq)]
pub struct EditorOutputState {
    pub console_entries: Vec<EditorConsoleEntry>,
    pub next_console_entry_id: u64,
    pub output_tab: EditorOutputTab,
}

impl EditorOutputState {
    /// Swift's `init(_ configure:)` without a configuration closure.
    pub fn new() -> Self {
        EditorOutputState::default()
    }

    /// Swift's `init(_ configure:)` with the closure applied.
    pub fn with_configure(configure: impl FnOnce(&mut EditorOutputState)) -> Self {
        let mut state = EditorOutputState::default();
        configure(&mut state);
        state
    }

    pub fn normalize(&mut self) {
        let highest = self
            .console_entries
            .iter()
            .map(|entry| entry.id)
            .max()
            .unwrap_or(0);
        self.next_console_entry_id = self.next_console_entry_id.max(highest.wrapping_add(1));
    }
}

impl Default for EditorOutputState {
    fn default() -> Self {
        EditorOutputState {
            console_entries: Vec::new(),
            next_console_entry_id: 1,
            output_tab: EditorOutputTab::Logs,
        }
    }
}

impl Serialize for EditorOutputState {
    /// Swift encoded an empty keyed container.
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_struct("EditorOutputState", 0)?.end()
    }
}

impl<'de> Deserialize<'de> for EditorOutputState {
    /// Swift read the container and dropped every key, keeping the defaults.
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let _ = IgnoredAny::deserialize(deserializer)?;
        Ok(EditorOutputState::default())
    }
}

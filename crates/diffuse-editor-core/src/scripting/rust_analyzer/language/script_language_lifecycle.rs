//! `Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/ScriptLanguageLifecycle.swift`.
//!
//! Transient health and retry policy, independent of authored document roots.

use std::sync::Arc;
use std::thread::JoinHandle;
use std::time::Instant;

use super::script_language_models::ScriptLanguageServiceState;

pub type StateHandler = Arc<dyn Fn(ScriptLanguageServiceUpdate) + Send + Sync>;

/// Transient health and retry policy, independent of authored document roots.
pub struct ScriptLanguageLifecycle {
    /// A fresh v4 UUID identifies this service generation.
    pub generation: String,
    pub connection_id: Option<String>,
    pub state: ScriptLanguageServiceState,
    pub on_state_change: Option<StateHandler>,
    pub recovery_attempt: u32,
    pub recovery_task: Option<JoinHandle<()>>,
    pub ready_since: Option<Instant>,
    pub metrics_task: Option<JoinHandle<()>>,
    /// Polls the project for edits made outside the editor.
    pub watch_task: Option<JoinHandle<()>>,
}

impl Default for ScriptLanguageLifecycle {
    fn default() -> Self {
        Self::new()
    }
}

impl ScriptLanguageLifecycle {
    pub fn new() -> Self {
        ScriptLanguageLifecycle {
            generation: diffuse_kernel::codable::new_uuid(),
            connection_id: None,
            state: ScriptLanguageServiceState::Inactive,
            on_state_change: None,
            recovery_attempt: 0,
            recovery_task: None,
            ready_since: None,
            metrics_task: None,
            watch_task: None,
        }
    }
}

/// Revision orders UI deliveries across stop, restart and recovery callbacks.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScriptLanguageServiceUpdate {
    pub revision: u64,
    pub state: ScriptLanguageServiceState,
}

impl ScriptLanguageServiceUpdate {
    pub fn new(revision: u64, state: ScriptLanguageServiceState) -> Self {
        ScriptLanguageServiceUpdate { revision, state }
    }
}

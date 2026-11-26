//! Context memory storage from `Application/AI/ContextMemory.swift`.

use std::fs;
use std::path::Path;

use diffuse_ai::context::world_view::WorldEntityRecord;
use diffuse_context_memory::context_memory_store::ContextMemoryStore;
use diffuse_intent::transactions::world_event::WorldEvent;

use crate::application::editor_application::EditorApplication;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::EditorConsoleSeverity;

impl EditorApplication {
    pub(crate) fn initialize_context_memory(
        path: &Path,
    ) -> (Option<std::sync::Arc<ContextMemoryStore>>, Option<String>) {
        let original_error = match ContextMemoryStore::with_storage(path) {
            Ok(store) => return (Some(std::sync::Arc::new(store)), None),
            Err(error) => error,
        };
        if !path.exists() {
            return (
                None,
                Some(format!(
                    "Context memory could not be initialized: {original_error}"
                )),
            );
        }
        let quarantine = path.with_extension(format!(
            "corrupt-{}.json",
            diffuse_kernel::codable::new_uuid()
        ));
        let recovered = fs::rename(path, &quarantine)
            .map_err(diffuse_context_memory::context_memory_store::ContextMemoryError::from)
            .and_then(|()| ContextMemoryStore::with_storage(path));
        match recovered {
            Ok(store) => (
                Some(std::sync::Arc::new(store)),
                Some(format!(
                    "The unreadable file was moved to {}: {original_error}",
                    quarantine.file_name().unwrap_or_default().to_string_lossy(),
                )),
            ),
            Err(error) => (
                None,
                Some(format!(
                    "Context memory is disabled because recovery failed: {error}; original error: {original_error}",
                )),
            ),
        }
    }

    pub(crate) fn flush_context_memory_before_shutdown(&self) {
        if let Some(store) = &self.context_memory_store
            && let Err(error) = store.flush()
        {
            self.store.dispatch(EditorAction::AppendConsoleMessage {
                message: "Failed to persist AI context memory".into(),
                severity: EditorConsoleSeverity::Error,
                detail: Some(error.to_string()),
                target: None,
                next_step: None,
            });
        }
    }

    /// `observeWorldEvents(_:)` — folds applied world events into the AI world
    /// context and the active session. The Swift version chains the previous
    /// observation task, so a slow flush never reorders events; the Rust port
    /// runs the same work synchronously on the caller's thread.
    pub(crate) fn observe_world_events(&self, events: &[WorldEvent]) {
        if events.is_empty() {
            return;
        }
        self.ai_world_context.observe_events(events.to_vec());
        if let Some(session) = self.session.borrow().clone() {
            session.observe_events(events.to_vec());
        }
    }

    /// `readAIWorldEntityRecord(ref:)` — the AI-visible record for one entity
    /// reference, or `None` when the world does not know it.
    pub(crate) fn read_ai_world_entity_record(&self, ref_: &str) -> Option<WorldEntityRecord> {
        self.ai_world_context.entity_record(ref_)
    }

    /// `jsonObject(_:)` — encodes a value and returns its JSON object form
    /// (`None` when the value is not encodable or not an object).
    pub(crate) fn json_object<T: serde::Serialize>(value: &T) -> Option<serde_json::Value> {
        serde_json::to_value(value).ok()
    }
}

//! Context memory storage from `Application/AI/ContextMemory.swift`.

use std::fs;
use std::path::Path;

use diffuse_context_memory::context_memory_store::ContextMemoryStore;

use crate::application::editor_application::EditorApplication;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::EditorConsoleSeverity;

impl EditorApplication {
    pub(crate) fn initialize_context_memory(
        path: &Path,
    ) -> (Option<ContextMemoryStore>, Option<String>) {
        let original_error = match ContextMemoryStore::with_storage(path) {
            Ok(store) => return (Some(store), None),
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
                Some(store),
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
}

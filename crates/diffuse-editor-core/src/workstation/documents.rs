//! Translation of `Editor/Sources/EditorCore/Workstation/Documents.swift`.
//!
//! Project-relative text documents, their open tabs and the diff tab shown by
//! the workbench.

use std::collections::BTreeMap;
use std::fmt::Display;
use std::path::Path;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use diffuse_documents::workspace::{DocumentError, DocumentWorkspace, TextDocument};

/// A request to put the caret somewhere, e.g. from the outline. `id` makes
/// repeated requests distinct.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorDocumentReveal {
    pub path: String,
    pub character_index: usize,
    pub id: u64,
}

/// Everything a view shows about the workspace, compared as one value so a
/// selection change re-renders views even when the document list is unchanged.
#[derive(Clone, Debug, PartialEq)]
pub struct EditorDocumentSnapshot {
    pub documents: Vec<TextDocument>,
    pub selected_path: Option<String>,
    pub error: Option<String>,
    pub reveal: Option<EditorDocumentReveal>,
    pub has_comparison: bool,
    pub shows_comparison: bool,
}

impl EditorDocumentSnapshot {
    /// The document in front; `None` while the diff tab is.
    pub fn selected(&self) -> Option<&TextDocument> {
        if self.shows_comparison {
            return None;
        }
        self.documents
            .iter()
            .find(|document| Some(&document.path) == self.selected_path.as_ref())
    }
}

struct WorkspaceState {
    documents: Vec<TextDocument>,
    selected_path: Option<String>,
    error: Option<String>,
    reveal: Option<EditorDocumentReveal>,
    has_comparison: bool,
    shows_comparison: bool,
}

pub struct EditorDocumentWorkspace {
    workspace: DocumentWorkspace,
    state: Mutex<WorkspaceState>,
    observers: Mutex<BTreeMap<u64, Arc<dyn Fn() + Send + Sync>>>,
    next_observer: AtomicU64,
    did_select: Mutex<Option<Arc<dyn Fn(Option<&str>) + Send + Sync>>>,
}

impl EditorDocumentWorkspace {
    pub fn new(root: &Path) -> Self {
        EditorDocumentWorkspace {
            workspace: DocumentWorkspace::new(root),
            state: Mutex::new(WorkspaceState {
                documents: Vec::new(),
                selected_path: None,
                error: None,
                reveal: None,
                has_comparison: false,
                shows_comparison: false,
            }),
            observers: Mutex::new(BTreeMap::new()),
            next_observer: AtomicU64::new(0),
            did_select: Mutex::new(None),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, WorkspaceState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn snapshot(&self) -> EditorDocumentSnapshot {
        let state = self.lock();
        EditorDocumentSnapshot {
            documents: state.documents.clone(),
            selected_path: state.selected_path.clone(),
            error: state.error.clone(),
            reveal: state.reveal.clone(),
            has_comparison: state.has_comparison,
            shows_comparison: state.shows_comparison,
        }
    }

    pub fn documents(&self) -> Vec<TextDocument> {
        self.lock().documents.clone()
    }

    pub fn selected_path(&self) -> Option<String> {
        self.lock().selected_path.clone()
    }

    pub fn error(&self) -> Option<String> {
        self.lock().error.clone()
    }

    pub fn has_unsaved_changes(&self) -> bool {
        self.lock()
            .documents
            .iter()
            .any(|document| document.is_dirty())
    }

    pub fn files(&self) -> Vec<String> {
        self.workspace.files()
    }

    pub fn set_did_select(&self, handler: Option<Arc<dyn Fn(Option<&str>) + Send + Sync>>) {
        *self
            .did_select
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = handler;
    }

    pub fn open(&self, path: &str) {
        self.lock().shows_comparison = false;
        let previous = self.lock().selected_path.clone();
        let result = self.workspace.open(path).map(|_| {
            self.lock().selected_path = Some(path.to_string());
        });
        self.finish(previous, result.map(|_| ()));
        self.announce_selection(path);
    }

    /// Closing the selected document selects its neighbour in tab order, so the
    /// editor never shows an empty pane while other documents stay open.
    pub fn close(&self, path: &str) {
        self.close_with_discard(path, false);
    }

    pub fn close_with_discard(&self, path: &str, discard: bool) {
        let order: Vec<String> = self
            .lock()
            .documents
            .iter()
            .map(|document| document.path.clone())
            .collect();
        let previous = self.lock().selected_path.clone();
        let result = self.workspace.close(path, discard).map(|_| {
            let selected = self.lock().selected_path.clone();
            if selected.as_deref() != Some(path) {
                return;
            }
            let Some(index) = order.iter().position(|candidate| candidate == path) else {
                return;
            };
            let remaining: Vec<&String> = order
                .iter()
                .filter(|candidate| *candidate != path)
                .collect();
            let next = if remaining.is_empty() {
                None
            } else {
                Some(remaining[index.min(remaining.len() - 1)].clone())
            };
            self.lock().selected_path = next;
        });
        self.finish(previous, result);
    }

    pub fn reload(&self, path: &str) {
        self.reload_with_discard(path, false);
    }

    pub fn reload_with_discard(&self, path: &str, discard: bool) {
        let previous = self.lock().selected_path.clone();
        let result = self
            .workspace
            .close(path, discard)
            .and_then(|()| self.workspace.open(path).map(|_| ()));
        self.finish(previous, result);
    }

    /// Re-reads every open document without unsaved edits, e.g. after a pull.
    /// Files that no longer exist close.
    pub fn reload_unmodified(&self) {
        let clean: Vec<String> = self
            .lock()
            .documents
            .iter()
            .filter(|document| !document.is_dirty() && document.exists_on_disk())
            .map(|document| document.path.clone())
            .collect();
        for path in clean {
            let previous = self.lock().selected_path.clone();
            let result = (|| {
                self.workspace.close(&path, false)?;
                let reopened = self.workspace.open(&path);
                if !reopened.as_ref().is_ok_and(TextDocument::exists_on_disk) {
                    let _ = self.workspace.close(&path, true);
                    let selected = self.lock().selected_path.clone();
                    if selected.as_deref() == Some(path.as_str()) {
                        let first = self
                            .workspace
                            .documents()
                            .first()
                            .map(|document| document.path.clone());
                        self.lock().selected_path = first;
                    }
                }
                Ok(())
            })();
            self.finish(previous, result);
        }
    }

    /// Creates a file and opens it in a tab.
    pub fn create(&self, path: &str, text: &str) -> bool {
        let previous = self.lock().selected_path.clone();
        let result = self.workspace.create(path, text);
        self.finish(previous, result);
        if self.error().is_some() {
            return false;
        }
        self.open(path);
        self.error().is_none()
    }

    /// Renames a file or folder; its open tabs follow it.
    pub fn move_to(&self, path: &str, destination: &str) -> bool {
        let previous = self.lock().selected_path.clone();
        let result = self.workspace.move_to(path, destination).map(|()| {
            if let Some(selected) = self.lock().selected_path.clone() {
                if selected == path || selected.starts_with(&format!("{path}/")) {
                    self.lock().selected_path =
                        Some(format!("{destination}{}", &selected[path.len()..]));
                }
            }
        });
        self.finish(previous, result);
        self.error().is_none()
    }

    /// Moves a file or folder to the Trash, closing its tabs.
    pub fn remove(&self, path: &str) -> bool {
        let order: Vec<String> = self
            .lock()
            .documents
            .iter()
            .map(|document| document.path.clone())
            .collect();
        let previous = self.lock().selected_path.clone();
        let result = self.workspace.remove(path).map(|()| {
            let Some(selected) = self.lock().selected_path.clone() else {
                return;
            };
            if !(selected == path || selected.starts_with(&format!("{path}/"))) {
                return;
            }
            let remaining: Vec<String> = self
                .workspace
                .documents()
                .iter()
                .map(|document| document.path.clone())
                .collect();
            let index = order
                .iter()
                .position(|candidate| *candidate == selected)
                .unwrap_or(0);
            let next = if remaining.is_empty() {
                None
            } else {
                Some(remaining[index.min(remaining.len() - 1)].clone())
            };
            self.lock().selected_path = next;
        });
        self.finish(previous, result);
        self.error().is_none()
    }

    pub fn edit(&self, path: &str, text: &str) {
        let previous = self.lock().selected_path.clone();
        let result = self.workspace.edit(path, text);
        self.finish(previous, result);
    }

    pub fn save(&self, path: &str) {
        let previous = self.lock().selected_path.clone();
        let result = self.workspace.save(path);
        self.finish(previous, result);
    }

    pub fn save_all(&self) -> bool {
        let previous = self.lock().selected_path.clone();
        let result = self.workspace.save_all();
        self.finish(previous, result);
        self.error().is_none()
    }

    pub fn read(&self, path: &str) -> Result<TextDocument, DocumentError> {
        let result = self.workspace.open(path);
        self.refresh();
        result
    }

    pub fn write(
        &self,
        path: &str,
        text: &str,
        expected: Option<&str>,
    ) -> Result<(), DocumentError> {
        let document = self.workspace.open(path)?;
        let unsaved_allowed = !document.is_dirty()
            || (!document.exists_on_disk() && document.text.is_empty() && expected.is_none());
        if !unsaved_allowed {
            return Err(DocumentError::UnsavedChanges);
        }
        let matches = match expected {
            None => !document.exists_on_disk(),
            Some(expected) => expected == document.text,
        };
        if !matches {
            return Err(DocumentError::ChangedOnDisk);
        }
        self.workspace.edit(path, text)?;
        self.workspace.save(path)?;
        self.refresh();
        Ok(())
    }

    pub fn report(&self, failure: &dyn Display) {
        self.lock().error = Some(failure.to_string());
        self.refresh();
    }

    /// Opens `path` and places the caret at a character index.
    pub fn reveal_document(&self, path: &str, character_index: usize) {
        self.open(path);
        if self.error().is_some() {
            return;
        }
        {
            let mut state = self.lock();
            let id = state.reveal.as_ref().map_or(0, |reveal| reveal.id) + 1;
            state.reveal = Some(EditorDocumentReveal {
                path: path.to_string(),
                character_index,
                id,
            });
        }
        self.refresh_snapshot();
    }

    /// Opens the diff tab, or brings it back, in front of the documents.
    pub fn show_comparison(&self) {
        let mut state = self.lock();
        state.has_comparison = true;
        state.shows_comparison = true;
        drop(state);
        self.refresh_snapshot();
    }

    pub fn close_comparison(&self) {
        let mut state = self.lock();
        state.has_comparison = false;
        state.shows_comparison = false;
        drop(state);
        self.refresh_snapshot();
    }

    pub fn register_observer(&self, handler: Arc<dyn Fn() + Send + Sync>) -> u64 {
        let token = self.next_observer.fetch_add(1, Ordering::SeqCst);
        self.observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(token, handler);
        token
    }

    pub fn unregister_observer(&self, token: u64) {
        self.observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&token);
    }

    fn finish(&self, previous: Option<String>, result: Result<(), DocumentError>) {
        self.lock().error = result.err().map(|error| error.error_description());
        self.refresh();
        let selected = self.lock().selected_path.clone();
        if selected != previous
            && let Some(handler) = self
                .did_select
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .clone()
        {
            handler(selected.as_deref());
        }
    }

    fn announce_selection(&self, path: &str) {
        if self.error().is_some() {
            return;
        }
        if let Some(handler) = self
            .did_select
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
        {
            handler(Some(path));
        }
    }

    fn refresh(&self) {
        let documents = self.workspace.documents();
        self.lock().documents = documents;
        self.refresh_snapshot();
    }

    fn refresh_snapshot(&self) {
        let handlers: Vec<Arc<dyn Fn() + Send + Sync>> = self
            .observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .cloned()
            .collect();
        for handler in handlers {
            handler();
        }
    }
}

//! Translation of `Editor/Sources/EditorCore/Workstation/Services.swift`.
//!
//! The workstation domains sharing one project root. Documents, the script
//! workspace, media, version control and tasks each keep their own persistence
//! and execution lifecycle.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Weak};

use cove_system::paths::PathIdentity;
use diffuse_documents::workspace::{DocumentError, TextDocument};
use diffuse_media::MediaError;

use crate::contributions::host::StepPlugins;
use crate::contributions::languages::LanguageCatalog;
use crate::contributions::runtime_access::PluginRuntimeAccess;
use crate::scripting::assets::script_workspace_model::ScriptWorkspaceModel;
use crate::tasks::runner::EditorTasks;
use crate::version_control::workspace::EditorVersionControl;
use crate::workstation::documents::EditorDocumentWorkspace;
use crate::workstation::media::EditorMediaWorkspace;

/// Handler installed on the document workspace when a tab is selected.
type DocumentSelectionHandler = Arc<dyn Fn(Option<&str>) + Send + Sync>;
/// Handler installed when version control rewrites files on disk.
type FilesChangedHandler = Arc<dyn Fn() + Send + Sync>;

/// Workstation documents have independent persistence and execution lifecycles.
pub struct EditorWorkstation {
    pub scripts: Arc<ScriptWorkspaceModel>,
    pub documents: EditorDocumentWorkspace,
    pub media: EditorMediaWorkspace,
    pub version_control: EditorVersionControl,
    pub tasks: Arc<EditorTasks>,
    root: PathBuf,
}

impl EditorWorkstation {
    /// `init(root:scripts:plugins:) throws`.
    ///
    /// The two `[weak self]` callbacks are installed through
    /// [`Arc::new_cyclic`], which hands out the weak reference Swift's capture
    /// list creates. The media workspace may throw, so it opens before the
    /// cycle is built.
    pub fn new(
        root: &Path,
        scripts: Arc<ScriptWorkspaceModel>,
        plugins: Arc<PluginRuntimeAccess>,
    ) -> Result<Arc<Self>, MediaError> {
        let root = PathIdentity::canonical_url(root);
        let media = EditorMediaWorkspace::new(&root)?;
        let plugins = StepPlugins::new(plugins);
        Ok(Arc::new_cyclic(|weak: &Weak<EditorWorkstation>| {
            let documents = EditorDocumentWorkspace::new(&root);
            // Every domain requests its binding from the same lifecycle owner.
            let version_control = EditorVersionControl::new(&root, plugins.clone());
            let tasks = Arc::new(EditorTasks::new(&root, plugins.clone()));
            // Every tab in the served language gets the language service:
            // scripts as part of the game, other project files analyzed in place.
            let did_select: DocumentSelectionHandler = {
                let weak = weak.clone();
                let root = root.clone();
                let scripts = scripts.clone();
                Arc::new(move |path| {
                    let Some(this) = weak.upgrade() else {
                        return;
                    };
                    let Some(path) = path else {
                        return;
                    };
                    let id = this.script_id_for_document(path).or_else(|| {
                        let served = LanguageCatalog::served()?;
                        if !served.matches(path) {
                            return None;
                        }
                        scripts.open_project_source(&root.join(path))
                    });
                    if let Some(id) = id {
                        scripts.select(&id);
                    }
                })
            };
            documents.set_did_select(Some(did_select));
            // A pull, discard or branch switch rewrote files: show what is on
            // disk wherever no unsaved edit would be lost.
            let did_change_files: FilesChangedHandler = {
                let weak = weak.clone();
                Arc::new(move || {
                    let Some(this) = weak.upgrade() else {
                        return;
                    };
                    this.documents.reload_unmodified();
                    this.scripts.refresh_from_disk();
                })
            };
            version_control.set_did_change_files(Some(did_change_files));
            EditorWorkstation {
                scripts,
                documents,
                media,
                version_control,
                tasks,
                root,
            }
        }))
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    pub fn has_unsaved_changes(&self) -> bool {
        self.scripts
            .snapshot()
            .documents
            .iter()
            .any(|document| document.is_dirty)
            || self.documents.has_unsaved_changes()
            || self.media.is_dirty()
    }

    pub fn save_all(&self) -> bool {
        self.scripts.persist_all()
            && self.documents.save_all()
            && (!self.media.is_dirty() || self.media.save())
    }
}

/// Project scripts open as document tabs, but their text belongs to the script
/// workspace, so builds and the language service see every keystroke.
/// These entry points pick the owner for a tab; callers never need to know.
impl EditorWorkstation {
    pub fn script_id_for_document(&self, path: &str) -> Option<String> {
        let url = PathIdentity::canonical_url(&self.root.join(path));
        self.scripts
            .snapshot()
            .documents
            .iter()
            .find(|document| PathIdentity::same_location(&document.file.url, &url))
            .map(|document| document.file.identifier.clone())
    }

    /// The project-relative tab path for a script, if it lives in the project.
    pub fn document_path_for_script(&self, id: &str) -> Option<String> {
        self.scripts
            .snapshot()
            .documents
            .iter()
            .find(|document| document.file.identifier == id)
            .and_then(|document| self.document_path_for(&document.file.url))
    }

    /// The project-relative path of a file or folder inside the project.
    pub fn document_path_for(&self, url: &Path) -> Option<String> {
        let path = PathIdentity::canonical_url(url);
        let path = path.to_string_lossy();
        let root = self.root.to_string_lossy();
        let base = if root.ends_with('/') {
            root.into_owned()
        } else {
            format!("{root}/")
        };
        path.strip_prefix(&base).map(str::to_string)
    }

    /// Adds `NewScript` (numbered when taken) and opens it in a tab.
    pub fn create_script(&self, source: &str) -> Option<String> {
        let taken: BTreeSet<String> = self
            .scripts
            .snapshot()
            .documents
            .iter()
            .map(|document| document.file.display_name.to_lowercase())
            .collect();
        let mut name = "NewScript".to_string();
        let mut suffix = 2;
        while taken.contains(&name.to_lowercase()) {
            name = format!("NewScript{suffix}");
            suffix += 1;
        }
        if !self.scripts.create_script(&name, source) {
            return None;
        }
        let id = self.scripts.snapshot().selected_script_id?;
        let path = self.document_path_for_script(&id)?;
        self.documents.open(&path);
        Some(path)
    }

    /// Deletes a project script with its tab; unsaved edits go with it.
    pub fn delete_script_at_document(&self, path: &str) -> bool {
        let Some(id) = self.script_id_for_document(path) else {
            return false;
        };
        self.scripts.revert(&id);
        if self
            .documents
            .documents()
            .iter()
            .any(|document| document.path == path)
        {
            self.documents.close_with_discard(path, true);
        }
        if !(self.scripts.select(&id) && self.scripts.delete_selected_script()) {
            return false;
        }
        // Deleting moved the script selection; give it back to the front tab.
        if let Some(front) = self.documents.selected_path() {
            self.documents.open(&front);
        }
        true
    }

    pub fn is_document_dirty(&self, document: &TextDocument) -> bool {
        let Some(id) = self.script_id_for_document(&document.path) else {
            return document.is_dirty();
        };
        self.scripts
            .snapshot()
            .documents
            .iter()
            .find(|candidate| candidate.file.identifier == id)
            .is_some_and(|candidate| candidate.is_dirty)
    }

    pub fn save_document(&self, path: &str) -> bool {
        if let Some(id) = self.script_id_for_document(path) {
            return self.scripts.persist(&id);
        }
        self.documents.save(path);
        self.documents.error().is_none()
    }

    pub fn revert_document(&self, path: &str) {
        if let Some(id) = self.script_id_for_document(path) {
            self.scripts.revert(&id);
        } else {
            self.documents.reload_with_discard(path, true);
        }
    }

    /// Closing a modified script without `discard` is refused like any other
    /// modified document; discarding drops its edits first.
    pub fn close_document(&self, path: &str, discard: bool) {
        if let Some(id) = self.script_id_for_document(path)
            && self
                .scripts
                .snapshot()
                .documents
                .iter()
                .find(|document| document.file.identifier == id)
                .is_some_and(|document| document.is_dirty)
        {
            if !discard {
                self.documents.report(&DocumentError::UnsavedChanges);
                return;
            }
            self.scripts.revert(&id);
        }
        self.documents.close_with_discard(path, discard);
        if let Some(id) = self.script_id_for_document(path)
            && !self
                .documents
                .documents()
                .iter()
                .any(|document| document.path == path)
        {
            self.scripts.close_project_source(&id);
        }
    }
}

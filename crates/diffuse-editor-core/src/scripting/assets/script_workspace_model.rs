//! `Editor/Sources/EditorCore/Scripting/Assets/ScriptWorkspaceModel.swift`.
//!
//! Single source of truth for script documents, diagnostics, build revisions,
//! and the runtime generation visible to the editor.
//!
//! D1 rewrite (MIGRATION.md §4): user scripts are Rust, built with cargo and
//! analyzed by rust-analyzer. The `Swift*` type names and the `.swift` display
//! strings are historical naming that §4 D1 explicitly permits keeping; the
//! manager scans `.rs` sources and `SwiftToolchain` resolves rustup/cargo.
//! Source references to SourceKit-LSP live in `scripting::rust_analyzer::*`.
//!
//! Swift is `@unchecked Sendable` + `@MainActor`: all mutations happen on the
//! main thread and background callbacks hop back to it. Rust has no async
//! runtime (§5.5), so the mutable state lives behind one [`Mutex`], every
//! `Task {}` becomes a named thread, and the language-service task chain uses
//! an `Arc<AtomicBool>` cancellation token plus a completion guard so a new
//! generation waits for the previous one the way `await previousTask?.value`
//! does. Handlers are always invoked after the state lock is released, so an
//! observer may call `snapshot()` again.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError, Weak};
use std::time::Duration;

use cove_system::paths::PathIdentity;
use cove_ui_compose::primitives::text::code::gutter_options::TextEditorAnnotations;
use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use diffuse_kernel::codable::new_uuid;

use crate::contributions::languages::LanguageCatalog;
use crate::scripting::assets::language_edit_history::{
    ScriptLanguageEditChange, ScriptLanguageEditHistory, ScriptLanguageEditValidation,
};
use crate::scripting::assets::script_directory_monitor::ScriptDirectoryMonitor;
use crate::scripting::dynamic::dynamic_script_manager::{
    CompilationStatus, CompilationStatusHandler, DynamicScriptManager, DynamicScriptManagerError,
    ScriptFile, ScriptLanguageSource,
};
use crate::scripting::dynamic::script_project_trust::{
    ScriptProjectTrustError, ScriptProjectTrustState,
};
use crate::scripting::rust_analyzer::language::details::ScriptLanguageServiceDetails;
use crate::scripting::rust_analyzer::language::editing::{
    ScriptLanguageEditError, ScriptWorkspaceEdit,
};
use crate::scripting::rust_analyzer::language::script_language_lifecycle::{
    ScriptLanguageServiceUpdate, StateHandler,
};
use crate::scripting::rust_analyzer::language::script_language_models::{
    ScriptLanguageDiagnostic, ScriptLanguageDiagnosticUpdate, ScriptLanguageServiceState,
};
use crate::scripting::rust_analyzer::language::watched_files::ScriptWatchedFiles;
use crate::scripting::script_language_support::{DetailsHandler, DiagnosticsHandler};
use crate::scripting::toolchain::activation::{
    ScriptToolchainActivation, ScriptToolchainLanguageIntent, ToolchainSuspend, ToolchainTransition,
};
use crate::scripting::toolchain::activity::ScriptToolchainActivity;
use crate::scripting::toolchain::installation::SwiftToolchainInstallProgress;
use crate::scripting::toolchain::preferences::SwiftToolchainPreferences;
use crate::scripting::toolchain::resolution::SwiftToolchain;

// MARK: - Public value types

/// Swift `enum ScriptDocumentBuildState: Sendable, Equatable`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum ScriptDocumentBuildState {
    #[default]
    Idle,
    Building(u64),
    Succeeded(u64),
    Cancelled(u64),
    Blocked {
        revision: u64,
        message: String,
    },
    Failed {
        revision: u64,
        message: String,
    },
}

impl ScriptDocumentBuildState {
    /// Swift `var isBuilding: Bool { if case .building = self { true } ... }`.
    pub fn is_building(&self) -> bool {
        matches!(self, ScriptDocumentBuildState::Building(_))
    }

    /// Swift `var isFailed: Bool { if case .failed = self { true } ... }`.
    pub fn is_failed(&self) -> bool {
        matches!(self, ScriptDocumentBuildState::Failed { .. })
    }
}

/// Swift `enum ScriptExternalChangeState: Sendable, Equatable`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum ScriptExternalChangeState {
    #[default]
    None,
    ModifiedOnDisk(String),
    DeletedOnDisk,
}

impl ScriptExternalChangeState {
    /// Swift `var requiresResolution: Bool { self != .none }`.
    pub fn requires_resolution(&self) -> bool {
        !matches!(self, ScriptExternalChangeState::None)
    }
}

/// Swift `struct ScriptWorkspaceDocument: Sendable, Equatable`.
///
/// The `didSet` observers of `source` and `savedSource` are reproduced by
/// [`ScriptWorkspaceDocument::set_source`] and
/// [`ScriptWorkspaceDocument::set_saved_source`]: `source` rebases the editor
/// annotations and refreshes the dirty flag, `savedSource` only refreshes it.
/// `is_dirty` is a cached value (§9 batch 256 note), refreshed at every write
/// point via [`ScriptWorkspaceDocument::refresh_dirty`]. Comparisons of
/// `TextBuffer` use `has_same_contents`, never `PartialEq`, because the Rust
/// `PartialEq` is an `Arc` identity comparison rather than a content one.
#[derive(Clone, Debug)]
pub struct ScriptWorkspaceDocument {
    pub file: ScriptFile,
    pub source: TextBuffer,
    pub annotations: TextEditorAnnotations,
    pub saved_source: TextBuffer,
    pub edit_revision: u64,
    pub saved_revision: u64,
    pub build_state: ScriptDocumentBuildState,
    pub loaded_revision: Option<u64>,
    pub output: String,
    pub diagnostics: Vec<ScriptLanguageDiagnostic>,
    pub external_change: ScriptExternalChangeState,
    /// A Rust file elsewhere in the project, open in a tab: analyzed by the
    /// language service like a script, saved in place, never built into the game.
    pub is_project_source: bool,
    /// Swift `public private(set) var isDirty`.
    pub is_dirty: bool,
}

impl ScriptWorkspaceDocument {
    /// Swift `init(file:source:)` — `self.source = source; savedSource = source`.
    pub fn new(file: ScriptFile, source: TextBuffer) -> Self {
        let saved_source = source.clone();
        let mut document = ScriptWorkspaceDocument {
            file,
            source,
            annotations: TextEditorAnnotations::new(),
            saved_source,
            edit_revision: 0,
            saved_revision: 0,
            build_state: ScriptDocumentBuildState::Idle,
            loaded_revision: None,
            output: String::new(),
            diagnostics: Vec::new(),
            external_change: ScriptExternalChangeState::None,
            is_project_source: false,
            is_dirty: false,
        };
        document.refresh_dirty();
        document
    }

    /// Swift `private mutating func refreshDirty()`.
    fn refresh_dirty(&mut self) {
        self.is_dirty = !self.source.has_same_contents(&self.saved_source);
    }

    /// Swift `source` `didSet { annotations.rebase(from: oldValue, to: source); refreshDirty() }`.
    fn set_source(&mut self, source: TextBuffer) {
        let previous = std::mem::replace(&mut self.source, source);
        self.annotations.rebase(&previous, &self.source);
        self.refresh_dirty();
    }

    /// Swift `savedSource` `didSet { refreshDirty() }`.
    fn set_saved_source(&mut self, saved_source: TextBuffer) {
        self.saved_source = saved_source;
        self.refresh_dirty();
    }
}

/// Swift's synthesized `Equatable`: every stored property, with `TextBuffer`
/// compared by content (`hasSameContents`) rather than the Rust `Arc` identity.
impl PartialEq for ScriptWorkspaceDocument {
    fn eq(&self, other: &Self) -> bool {
        self.file == other.file
            && self.source.has_same_contents(&other.source)
            && self.annotations == other.annotations
            && self.saved_source.has_same_contents(&other.saved_source)
            && self.edit_revision == other.edit_revision
            && self.saved_revision == other.saved_revision
            && self.build_state == other.build_state
            && self.loaded_revision == other.loaded_revision
            && self.output == other.output
            && self.diagnostics == other.diagnostics
            && self.external_change == other.external_change
            && self.is_project_source == other.is_project_source
            && self.is_dirty == other.is_dirty
    }
}

/// Swift `struct ScriptWorkspaceSnapshot: Sendable, Equatable`.
#[derive(Clone, Debug, PartialEq)]
pub struct ScriptWorkspaceSnapshot {
    pub documents: Vec<ScriptWorkspaceDocument>,
    pub selected_script_id: Option<String>,
    pub language_service_state: ScriptLanguageServiceState,
    pub is_language_service_message_dismissed: bool,
    pub language_service_details: Option<ScriptLanguageServiceDetails>,
    pub swift_toolchain: Option<SwiftToolchain>,
    pub toolchain_activity: ScriptToolchainActivity,
    pub trust_state: ScriptProjectTrustState,
    pub trust_warning: Option<String>,
}

impl ScriptWorkspaceSnapshot {
    /// Swift `var selectedDocument: ScriptWorkspaceDocument?`.
    pub fn selected_document(&self) -> Option<ScriptWorkspaceDocument> {
        let selected_script_id = self.selected_script_id.as_ref()?;
        self.documents
            .iter()
            .find(|document| document.file.identifier == *selected_script_id)
            .cloned()
    }

    /// Swift `var scripts: [ScriptWorkspaceDocument]` — gameplay scripts under
    /// `Scripts/`, which build into the game.
    pub fn scripts(&self) -> Vec<ScriptWorkspaceDocument> {
        self.documents
            .iter()
            .filter(|document| !document.is_project_source)
            .cloned()
            .collect()
    }
}

// MARK: - Handler aliases

/// Swift `typealias ScriptLoadedHandler = @Sendable (ScriptFile) -> Void`.
pub type ScriptLoadedHandler = Arc<dyn Fn(&ScriptFile) + Send + Sync>;
/// Swift `typealias ScriptDeletedHandler = @Sendable (ScriptFile) -> Void`.
pub type ScriptDeletedHandler = Arc<dyn Fn(&ScriptFile) + Send + Sync>;
/// Swift `typealias BuildFailedHandler = @Sendable (ScriptFile, String) -> Void`.
pub type BuildFailedHandler = Arc<dyn Fn(&ScriptFile, &str) + Send + Sync>;

// MARK: - Observer registry

/// Minimal, behaviour-faithful replacement for Swift's
/// `_ObservablePublisher<ScriptWorkspaceModel>`: a token (`u64`, the same token
/// type the rest of this crate uses) addresses a handler and `publish()` fires
/// every handler on every `publisher.send()`, after the state lock is released.
struct ObserverRegistry {
    next: AtomicU64,
    handlers: Mutex<BTreeMap<u64, Arc<dyn Fn() + Send + Sync>>>,
}

impl ObserverRegistry {
    fn new() -> Self {
        ObserverRegistry {
            next: AtomicU64::new(0),
            handlers: Mutex::new(BTreeMap::new()),
        }
    }

    fn register(&self, handler: Arc<dyn Fn() + Send + Sync>) -> u64 {
        let token = self.next.fetch_add(1, Ordering::SeqCst);
        self.handlers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .insert(token, handler);
        token
    }

    fn unregister(&self, token: u64) {
        self.handlers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(&token);
    }

    fn notify(&self) {
        let handlers: Vec<Arc<dyn Fn() + Send + Sync>> = self
            .handlers
            .lock()
            .unwrap_or_else(PoisonError::into_inner)
            .values()
            .cloned()
            .collect();
        for handler in handlers {
            handler();
        }
    }
}

// MARK: - Language-service task chain

/// One generation of the language-service task: `cancel` mirrors
/// `Task.cancel()`/`Task.isCancelled`, `done` lets the next generation await
/// `previousTask?.value`.
#[derive(Clone)]
struct LanguageServiceTask {
    cancel: Arc<AtomicBool>,
    done: Arc<AtomicBool>,
}

/// Sets `done` on every exit path of a language-service thread.
struct CompletionGuard(Arc<AtomicBool>);

impl Drop for CompletionGuard {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

// MARK: - Model state

struct ModelState {
    snapshot: ScriptWorkspaceSnapshot,
    did_start_language_service: bool,
    language_service_generation: String,
    language_service_revision: u64,
    language_service_suspended: bool,
    toolchain_language_intent: Option<ScriptToolchainLanguageIntent>,
    language_edit_history: ScriptLanguageEditHistory,
    toolchain_activity_generation: String,
    language_service_task: Option<LanguageServiceTask>,
}

impl ModelState {
    /// Swift `private func documentIndex(scriptID:)`.
    fn document_index(&self, script_id: &str) -> Option<usize> {
        self.snapshot
            .documents
            .iter()
            .position(|document| document.file.identifier == script_id)
    }

    /// Swift `private var selectedDocumentIndex: Int?`.
    fn selected_document_index(&self) -> Option<usize> {
        let selected_script_id = self.snapshot.selected_script_id.as_ref()?;
        self.document_index(selected_script_id)
    }

    /// Swift `private var languageSources: [ScriptLanguageSource]`.
    fn language_sources(&self) -> Vec<ScriptLanguageSource> {
        self.snapshot
            .documents
            .iter()
            .map(|document| {
                let mut source =
                    ScriptLanguageSource::new(document.file.clone(), document.source.clone());
                source.revision = document.edit_revision;
                source.is_project_source = document.is_project_source;
                source
            })
            .collect()
    }

    /// Swift `source` `didSet` sequence for an in-place replacement.
    fn set_source(&mut self, index: usize, source: TextBuffer) {
        self.snapshot.documents[index].set_source(source);
    }

    /// Swift `savedSource` `didSet` sequence for an in-place replacement.
    fn set_saved_source(&mut self, index: usize, saved_source: TextBuffer) {
        self.snapshot.documents[index].set_saved_source(saved_source);
    }

    /// Swift `private func adoptDiskSource(_ source:at:)`.
    fn adopt_disk_source(&mut self, source: &str, index: usize) {
        if index >= self.snapshot.documents.len() {
            return;
        }
        let buffer = TextBuffer::new(source);
        self.set_source(index, buffer.clone());
        self.set_saved_source(index, buffer);
        let document = &mut self.snapshot.documents[index];
        document.edit_revision = document.edit_revision.wrapping_add(1);
        document.saved_revision = document.edit_revision;
        document.build_state = ScriptDocumentBuildState::Idle;
        document.external_change = ScriptExternalChangeState::None;
        document.output = format!(
            "Reloaded external changes in {}.swift",
            document.file.display_name
        );
    }

    /// Swift `private func sortDocuments()` — `localizedCaseInsensitiveCompare`.
    fn sort_documents(&mut self) {
        self.snapshot.documents.sort_by(|left, right| {
            left.file
                .display_name
                .to_lowercase()
                .cmp(&right.file.display_name.to_lowercase())
        });
    }
}

// MARK: - Model

/// Swift `public final class ScriptWorkspaceModel: _ObservableObject, @unchecked Sendable`.
pub struct ScriptWorkspaceModel {
    state: Mutex<ModelState>,
    manager: Arc<DynamicScriptManager>,
    on_script_loaded: Option<ScriptLoadedHandler>,
    on_script_deleted: Option<ScriptDeletedHandler>,
    on_build_failed: Option<BuildFailedHandler>,
    directory_monitor: ScriptDirectoryMonitor,
    project_uses_language: bool,
    self_weak: Weak<ScriptWorkspaceModel>,
    observers: ObserverRegistry,
}

impl ScriptWorkspaceModel {
    pub(crate) fn manager(&self) -> &Arc<DynamicScriptManager> {
        &self.manager
    }

    /// Swift `init(manager:onScriptLoaded:onScriptDeleted:onBuildFailed:) throws`
    /// with its three `= nil` handler defaults.
    pub fn new(manager: Arc<DynamicScriptManager>) -> Result<Arc<Self>, DynamicScriptManagerError> {
        Self::with_handlers(manager, None, None, None)
    }

    /// The designated initializer with every handler supplied.
    pub fn with_handlers(
        manager: Arc<DynamicScriptManager>,
        on_script_loaded: Option<ScriptLoadedHandler>,
        on_script_deleted: Option<ScriptDeletedHandler>,
        on_build_failed: Option<BuildFailedHandler>,
    ) -> Result<Arc<Self>, DynamicScriptManagerError> {
        let documents: Vec<ScriptWorkspaceDocument> = manager
            .scan_script_files()?
            .into_iter()
            .map(|file| {
                let text = manager.read_source(&file.url)?;
                Ok(ScriptWorkspaceDocument::new(file, TextBuffer::new(&text)))
            })
            .collect::<Result<Vec<_>, DynamicScriptManagerError>>()?;

        let scripts_directory_url = manager.scripts_directory_url();
        let project_root = scripts_directory_url
            .parent()
            .map(|parent| parent.to_path_buf())
            .unwrap_or_else(|| scripts_directory_url.clone());
        let project_uses_language = LanguageCatalog::served()
            .map(|served| {
                let extensions: BTreeSet<String> =
                    served.language.extensions.iter().cloned().collect();
                ScriptWatchedFiles::contains(&project_root, &extensions)
            })
            .unwrap_or(false);

        let documents_empty = documents.is_empty();
        let selected_script_id = documents
            .first()
            .map(|document| document.file.identifier.clone());
        let snapshot = ScriptWorkspaceSnapshot {
            documents,
            selected_script_id,
            language_service_state: if documents_empty && !project_uses_language {
                ScriptLanguageServiceState::Inactive
            } else {
                ScriptLanguageServiceState::Starting
            },
            is_language_service_message_dismissed: false,
            language_service_details: None,
            swift_toolchain: manager.swift_toolchain(),
            toolchain_activity: ScriptToolchainActivity::Idle,
            trust_state: manager.project_trust_state(),
            trust_warning: manager.trust_store_warning().map(str::to_string),
        };

        Ok(Arc::new_cyclic(|weak: &Weak<ScriptWorkspaceModel>| {
            let directory_monitor = ScriptDirectoryMonitor::new(scripts_directory_url.clone());
            {
                let weak = weak.clone();
                directory_monitor.start(Arc::new(move || {
                    if let Some(model) = weak.upgrade() {
                        model.refresh_from_disk();
                    }
                }));
            }
            let state = ModelState {
                snapshot,
                did_start_language_service: false,
                language_service_generation: new_uuid(),
                language_service_revision: 0,
                language_service_suspended: false,
                toolchain_language_intent: None,
                language_edit_history: ScriptLanguageEditHistory::new(),
                toolchain_activity_generation: new_uuid(),
                language_service_task: None,
            };
            ScriptWorkspaceModel {
                state: Mutex::new(state),
                manager,
                on_script_loaded,
                on_script_deleted,
                on_build_failed,
                directory_monitor,
                project_uses_language,
                self_weak: weak.clone(),
                observers: ObserverRegistry::new(),
            }
        }))
    }

    fn lock(&self) -> MutexGuard<'_, ModelState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Swift `private var wantsLanguageService: Bool`.
    fn wants_language_service(&self, state: &ModelState) -> bool {
        !state.snapshot.documents.is_empty() || self.project_uses_language
    }

    /// Swift `private func publish()` — `publisher.send()`.
    fn publish(&self) {
        self.observers.notify();
    }

    /// Swift `public func snapshot` getter.
    pub fn snapshot(&self) -> ScriptWorkspaceSnapshot {
        self.lock().snapshot.clone()
    }

    // MARK: - Shutdown

    /// Swift `public func shutdown()`.
    pub fn shutdown(&self) {
        self.directory_monitor.stop();
        let identifiers: Vec<String> = self
            .lock()
            .snapshot
            .documents
            .iter()
            .map(|document| document.file.identifier.clone())
            .collect();
        for identifier in identifiers {
            self.manager.cancel_build(&identifier);
        }
        self.stop_language_service();
    }

    /// Swift `public func stopLanguageService()`.
    pub fn stop_language_service(&self) {
        {
            let mut state = self.lock();
            if let Some(intent) = state.toolchain_language_intent.as_mut() {
                intent.suspended = true;
            }
        }
        self.suspend_language_service();
    }

    /// Swift `func stopLanguageServiceForPluginChange()`.
    pub fn stop_language_service_for_plugin_change(&self) {
        self.suspend_language_service();
    }

    /// Swift `private func suspendLanguageService()`.
    fn suspend_language_service(&self) {
        {
            let mut state = self.lock();
            state.language_service_suspended = true;
            state.language_service_generation = new_uuid();
            state.did_start_language_service = false;
            state.snapshot.language_service_state = ScriptLanguageServiceState::Inactive;
            if let Some(details) = state.snapshot.language_service_details.as_mut() {
                details.resident_memory_bytes = None;
                details.indexing = None;
            }
            for document in state.snapshot.documents.iter_mut() {
                document.diagnostics.clear();
            }
        }
        self.publish();
        // Stop can interrupt initialize; waiting for its task first would keep
        // the server alive until the 30-second startup timeout.
        self.cancel_language_service_task();
        let manager = self.manager.clone();
        self.spawn_language_service_task(false, move || manager.stop_language_service());
    }

    /// Swift `public func startLanguageService()`.
    pub fn start_language_service(&self) {
        let (generation, sources) = {
            let mut state = self.lock();
            if state.toolchain_language_intent.is_some() {
                if let Some(intent) = state.toolchain_language_intent.as_mut() {
                    intent.suspended = false;
                }
                return;
            }
            state.language_service_suspended = false;
            let wants = self.wants_language_service(&state);
            if state.did_start_language_service || !wants {
                return;
            }
            state.did_start_language_service = true;
            let generation = new_uuid();
            state.language_service_generation = generation.clone();
            state.language_service_revision = 0;
            state.snapshot.language_service_state = ScriptLanguageServiceState::Starting;
            state.snapshot.language_service_details = None;
            state.snapshot.is_language_service_message_dismissed = false;
            let sources = state.language_sources();
            (generation, sources)
        };
        self.publish();

        let manager = self.manager.clone();
        let weak = self.self_weak.clone();
        self.spawn_language_service_task(true, move || {
            let outcome: Result<(), String> = (|| {
                manager.language_plugin.activate_if_needed()?;

                let diagnostics_generation = generation.clone();
                let diagnostics_weak = weak.clone();
                let on_diagnostics: DiagnosticsHandler = Arc::new(move |update| {
                    let Some(model) = diagnostics_weak.upgrade() else {
                        return;
                    };
                    if model.generation_matches(&diagnostics_generation) {
                        model.apply_diagnostics(update);
                    }
                });

                let state_generation = generation.clone();
                let state_weak = weak.clone();
                let on_state_change: StateHandler = Arc::new(move |update| {
                    let Some(model) = state_weak.upgrade() else {
                        return;
                    };
                    if model.generation_matches(&state_generation) {
                        model.apply_language_service_state(update);
                    }
                });

                let details_generation = generation.clone();
                let details_weak = weak.clone();
                let on_details_change: DetailsHandler = Arc::new(move |details| {
                    let Some(model) = details_weak.upgrade() else {
                        return;
                    };
                    model.apply_language_service_details(details, &details_generation);
                });

                manager
                    .start_language_service(
                        &sources,
                        on_diagnostics,
                        Some(on_state_change),
                        Some(on_details_change),
                    )
                    .map_err(|error| error.to_string())?;

                let current: Vec<ScriptLanguageSource> = match weak.upgrade() {
                    Some(model) => model.language_sources_for_generation(&generation),
                    None => Vec::new(),
                };
                for source in &current {
                    manager
                        .update_language_source(
                            &source.file.identifier,
                            &source.text,
                            source.revision,
                        )
                        .map_err(|error| error.to_string())?;
                }
                Ok(())
            })();
            if let Err(message) = outcome
                && let Some(model) = weak.upgrade()
            {
                model.apply_language_service_unavailable(&generation, message);
            }
        });
    }

    /// Swift `func startLanguageServiceForPluginChange()`.
    pub fn start_language_service_for_plugin_change(&self) {
        if self.lock().toolchain_language_intent.is_some() {
            return;
        }
        self.start_language_service();
    }

    // MARK: - Selection & sources

    /// Swift `@discardableResult public func select(scriptID:) -> Bool`.
    pub fn select(&self, script_id: &str) -> bool {
        {
            let mut state = self.lock();
            if state.snapshot.selected_script_id.as_deref() == Some(script_id) {
                return true;
            }
            if !state
                .snapshot
                .documents
                .iter()
                .any(|document| document.file.identifier == script_id)
            {
                return false;
            }
            state.snapshot.selected_script_id = Some(script_id.to_string());
        }
        self.publish();
        true
    }

    /// Swift `public func updateSelectedSource(_ source: TextBuffer)`.
    pub fn update_selected_source(&self, source: TextBuffer) {
        let Some(index) = self.lock().selected_document_index() else {
            return;
        };
        self.replace_source(index, source);
    }

    /// Swift `@discardableResult public func persist(scriptID:) -> Bool`.
    /// Saves one script whether or not it is selected; unsaved edits in other
    /// scripts stay unsaved, like document tabs.
    pub fn persist(&self, script_id: &str) -> bool {
        let Some(index) = self.lock().document_index(script_id) else {
            return false;
        };
        self.persist_script_at(index)
    }

    /// Swift `@discardableResult public func openProjectSource(_ url: URL) -> String?`.
    /// Opens a Rust file outside `Scripts/` for the language service and
    /// returns its identifier; an open file keeps its identifier.
    pub fn open_project_source(&self, path: &Path) -> Option<String> {
        let url = PathIdentity::canonical_url(path);
        let open = self.lock().snapshot.documents.iter().find_map(|document| {
            if PathIdentity::canonical_url(&document.file.url) == url {
                Some(document.file.identifier.clone())
            } else {
                None
            }
        });
        if let Some(identifier) = open {
            return Some(identifier);
        }
        let text = self.manager.read_source(&url).ok()?;
        let file = ScriptFile::new(url);
        let mut document = ScriptWorkspaceDocument::new(file.clone(), TextBuffer::new(&text));
        document.is_project_source = true;
        let identifier = document.file.identifier.clone();
        let mut language_source = ScriptLanguageSource::new(file, document.source.clone());
        language_source.is_project_source = true;

        let did_start_language_service = {
            let mut state = self.lock();
            state.snapshot.documents.push(document);
            state.sort_documents();
            state.did_start_language_service
        };
        self.publish();
        if did_start_language_service {
            let manager = self.manager.clone();
            spawn_background("script-open-project-source", move || {
                let _ = manager.open_project_source(&language_source);
            });
        } else {
            self.synchronize_language_service();
        }
        Some(identifier)
    }

    /// Swift `public func closeProjectSource(scriptID:)` — forgets a project
    /// source whose tab closed; scripts are never closed.
    pub fn close_project_source(&self, script_id: &str) {
        let (should_synchronize, identifier) = {
            let mut state = self.lock();
            let Some(index) = state.document_index(script_id) else {
                return;
            };
            if !state.snapshot.documents[index].is_project_source {
                return;
            }
            state.snapshot.documents.remove(index);
            if state.snapshot.selected_script_id.as_deref() == Some(script_id) {
                state.snapshot.selected_script_id = state
                    .snapshot
                    .documents
                    .first()
                    .map(|document| document.file.identifier.clone());
            }
            let wants = self.wants_language_service(&state);
            (!wants, script_id.to_string())
        };
        self.publish();
        if should_synchronize {
            self.synchronize_language_service();
        } else {
            let manager = self.manager.clone();
            spawn_background("script-close-project-source", move || {
                manager.close_project_source(&identifier);
            });
        }
    }

    /// Swift `private func projectSourceChange(_:) -> ScriptExternalChangeState`.
    fn project_source_change(
        &self,
        document: &ScriptWorkspaceDocument,
    ) -> ScriptExternalChangeState {
        match self.manager.read_source(&document.file.url) {
            Ok(disk) => {
                if disk == document.saved_source.string_value() {
                    ScriptExternalChangeState::None
                } else {
                    ScriptExternalChangeState::ModifiedOnDisk(disk)
                }
            }
            Err(_) => ScriptExternalChangeState::DeletedOnDisk,
        }
    }

    /// Swift `public func revert(scriptID:)` — drops unsaved edits and returns
    /// to the saved text.
    pub fn revert(&self, script_id: &str) {
        let found = {
            let state = self.lock();
            state.document_index(script_id).and_then(|index| {
                let document = &state.snapshot.documents[index];
                if document.is_dirty {
                    Some((index, document.saved_source.clone()))
                } else {
                    None
                }
            })
        };
        let Some((index, saved_source)) = found else {
            return;
        };
        self.replace_source(index, saved_source);
    }

    /// Swift `private func replaceSource(at:with:)`.
    fn replace_source(&self, index: usize, source: TextBuffer) {
        let (script_id, revision) = {
            let mut state = self.lock();
            if index >= state.snapshot.documents.len() {
                return;
            }
            if state.snapshot.documents[index]
                .source
                .has_same_contents(&source)
            {
                return;
            }
            state.set_source(index, source.clone());
            state.snapshot.documents[index].diagnostics.clear();
            state.snapshot.documents[index].edit_revision = state.snapshot.documents[index]
                .edit_revision
                .wrapping_add(1);
            state.language_edit_history.redo.clear();
            let script_id = state.snapshot.documents[index].file.identifier.clone();
            let revision = state.snapshot.documents[index].edit_revision;
            (script_id, revision)
        };
        self.publish();
        let manager = self.manager.clone();
        spawn_background("script-language-source-update", move || {
            let _ = manager.update_language_source(&script_id, &source, revision);
        });
    }

    /// Swift `public func setEditorAnnotations(_:for:)` — session presentation
    /// never dirties source or enters the authored file.
    pub fn set_editor_annotations(&self, annotations: TextEditorAnnotations, script_id: &str) {
        {
            let mut state = self.lock();
            let Some(index) = state
                .snapshot
                .documents
                .iter()
                .position(|document| document.file.identifier == script_id)
            else {
                return;
            };
            if state.snapshot.documents[index].annotations == annotations {
                return;
            }
            state.snapshot.documents[index].annotations = annotations;
        }
        self.publish();
    }

    // MARK: - Language edits, undo & redo

    /// Swift `public var canUndoLanguageEdit: Bool`.
    pub fn can_undo_language_edit(&self) -> bool {
        let changes = self.lock().language_edit_history.undo.last().cloned();
        match changes {
            Some(changes) => self.validate_language_changes(&changes, true).is_ok(),
            None => false,
        }
    }

    /// Swift `public var canRedoLanguageEdit: Bool`.
    pub fn can_redo_language_edit(&self) -> bool {
        let changes = self.lock().language_edit_history.redo.last().cloned();
        match changes {
            Some(changes) => self.validate_language_changes(&changes, false).is_ok(),
            None => false,
        }
    }

    /// Swift `public func applyLanguageEdit(_ edit:) throws`.
    pub fn apply_language_edit(
        &self,
        edit: &ScriptWorkspaceEdit,
    ) -> Result<(), ScriptLanguageEditError> {
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let mut changes: Vec<ScriptLanguageEditChange> = Vec::new();
        {
            let state = self.lock();
            for document_edit in &edit.documents {
                if !seen.insert(document_edit.script_id.clone()) {
                    return Err(ScriptLanguageEditError::DuplicateDocument);
                }
                let Some(index) = state.document_index(&document_edit.script_id) else {
                    return Err(ScriptLanguageEditError::StaleDocument(
                        document_edit.script_id.clone(),
                    ));
                };
                let document = state.snapshot.documents[index].clone();
                if document.edit_revision != document_edit.source_revision
                    || document.external_change != ScriptExternalChangeState::None
                {
                    return Err(ScriptLanguageEditError::StaleDocument(
                        document.file.display_name.clone(),
                    ));
                }
                let mut replacements: Vec<(std::ops::Range<usize>, String)> = Vec::new();
                for edit_item in &document_edit.edits {
                    let range =
                        ScriptLanguageEditValidation::range(edit_item.range, &document.source)?;
                    replacements.push((range, edit_item.text.clone()));
                }
                replacements.sort_by_key(|item| item.0.start);
                for offset in 1..replacements.len() {
                    let previous = &replacements[offset - 1].0;
                    let current = &replacements[offset].0;
                    if !(previous.end <= current.start && previous.start != current.start) {
                        return Err(ScriptLanguageEditError::OverlappingEdits);
                    }
                }
                let mut after = document.source.clone();
                for replacement in replacements.iter().rev() {
                    after = after.replace(replacement.0.clone(), &replacement.1);
                }
                if !document.source.has_same_contents(&after) {
                    changes.push(ScriptLanguageEditChange::new(
                        document_edit.script_id.clone(),
                        document.source.clone(),
                        after,
                    ));
                }
            }
        }
        self.apply_language_changes(&changes, false);
        {
            let mut state = self.lock();
            state.language_edit_history.record(changes);
        }
        self.publish();
        Ok(())
    }

    /// Swift `public func undoLanguageEdit() throws`.
    pub fn undo_language_edit(&self) -> Result<(), ScriptLanguageEditError> {
        let changes = self.lock().language_edit_history.undo.last().cloned();
        let Some(changes) = changes else {
            return Err(ScriptLanguageEditError::NoHistory);
        };
        self.validate_language_changes(&changes, true)?;
        self.apply_language_changes(&changes, true);
        {
            let mut state = self.lock();
            state.language_edit_history.undo.pop();
            state.language_edit_history.redo.push(changes);
        }
        self.publish();
        Ok(())
    }

    /// Swift `public func redoLanguageEdit() throws`.
    pub fn redo_language_edit(&self) -> Result<(), ScriptLanguageEditError> {
        let changes = self.lock().language_edit_history.redo.last().cloned();
        let Some(changes) = changes else {
            return Err(ScriptLanguageEditError::NoHistory);
        };
        self.validate_language_changes(&changes, false)?;
        self.apply_language_changes(&changes, false);
        {
            let mut state = self.lock();
            state.language_edit_history.redo.pop();
            state.language_edit_history.undo.push(changes);
        }
        self.publish();
        Ok(())
    }

    /// Swift `private func validateLanguageChanges(_:undoing:) throws`.
    fn validate_language_changes(
        &self,
        changes: &[ScriptLanguageEditChange],
        undoing: bool,
    ) -> Result<(), ScriptLanguageEditError> {
        let state = self.lock();
        for change in changes {
            let Some(document) = state
                .snapshot
                .documents
                .iter()
                .find(|document| document.file.identifier == change.script_id)
            else {
                return Err(ScriptLanguageEditError::StaleDocument(
                    change.script_id.clone(),
                ));
            };
            let expected = if undoing {
                &change.after
            } else {
                &change.before
            };
            if document.external_change != ScriptExternalChangeState::None
                || !document.source.has_same_contents(expected)
            {
                return Err(ScriptLanguageEditError::StaleDocument(
                    change.script_id.clone(),
                ));
            }
        }
        Ok(())
    }

    /// Swift `private func applyLanguageChanges(_:undoing:)`.
    fn apply_language_changes(&self, changes: &[ScriptLanguageEditChange], undoing: bool) {
        let mut sources: Vec<ScriptLanguageSource> = Vec::new();
        {
            let mut state = self.lock();
            for change in changes {
                let Some(index) = state.document_index(&change.script_id) else {
                    continue;
                };
                let value = if undoing {
                    change.before.clone()
                } else {
                    change.after.clone()
                };
                state.set_source(index, value);
                state.snapshot.documents[index].edit_revision = state.snapshot.documents[index]
                    .edit_revision
                    .wrapping_add(1);
                state.snapshot.documents[index].diagnostics.clear();
                let mut source = ScriptLanguageSource::new(
                    state.snapshot.documents[index].file.clone(),
                    state.snapshot.documents[index].source.clone(),
                );
                source.revision = state.snapshot.documents[index].edit_revision;
                sources.push(source);
            }
        }
        let manager = self.manager.clone();
        spawn_background("script-language-changes", move || {
            for source in &sources {
                let _ = manager.update_language_source(
                    &source.file.identifier,
                    &source.text,
                    source.revision,
                );
            }
        });
    }

    // MARK: - Persistence

    /// Swift `@discardableResult public func persistSelected(reportSuccess: Bool = false) -> Bool`.
    pub fn persist_selected(&self, report_success: bool) -> bool {
        let Some(index) = self.lock().selected_document_index() else {
            return true;
        };
        let (url, source_text, source_buffer, edit_revision, display_name) = {
            let state = self.lock();
            let document = &state.snapshot.documents[index];
            if !document.is_dirty {
                return true;
            }
            (
                document.file.url.clone(),
                document.source.string_value(),
                document.source.clone(),
                document.edit_revision,
                document.file.display_name.clone(),
            )
        };
        match self.manager.write_source(&source_text, &url) {
            Ok(()) => {
                {
                    let mut state = self.lock();
                    state.set_saved_source(index, source_buffer);
                    state.snapshot.documents[index].saved_revision = edit_revision;
                    if report_success {
                        state.snapshot.documents[index].output =
                            format!("Saved {display_name}.swift");
                    }
                }
                self.publish();
                true
            }
            Err(error) => {
                self.record_failure(&error.to_string(), index);
                false
            }
        }
    }

    /// The Swift `reportSuccess: Bool = false` default.
    pub fn persist_selected_with_defaults(&self) -> bool {
        self.persist_selected(false)
    }

    /// Swift `@discardableResult public func persistAll() -> Bool`.
    pub fn persist_all(&self) -> bool {
        let count = self.lock().snapshot.documents.len();
        for index in 0..count {
            if !self.persist_script_at(index) {
                return false;
            }
        }
        true
    }

    /// Swift `@discardableResult public func createScript(name:source:) -> Bool`.
    pub fn create_script(&self, name: &str, source: &str) -> bool {
        let outcome: Result<(ScriptFile, TextBuffer), String> = (|| {
            let url = self
                .manager
                .create_script(name, source)
                .map_err(|error| error.to_string())?;
            let file = self
                .manager
                .script_file_at(&url)
                .map_err(|error| error.to_string())?
                .ok_or_else(|| {
                    ScriptWorkspaceError::CreatedScriptMissing(url.to_string_lossy().into_owned())
                        .to_string()
                })?;
            Ok((file, TextBuffer::new(source)))
        })();
        let (file, buffer) = match outcome {
            Ok(value) => value,
            Err(message) => {
                self.record_workspace_failure(&message);
                return false;
            }
        };
        {
            let mut state = self.lock();
            state
                .snapshot
                .documents
                .push(ScriptWorkspaceDocument::new(file.clone(), buffer));
            state.sort_documents();
            state.snapshot.selected_script_id = Some(file.identifier.clone());
        }
        self.publish();
        self.synchronize_language_service();
        true
    }

    /// Swift `@discardableResult public func deleteSelectedScript() -> Bool`.
    pub fn delete_selected_script(&self) -> bool {
        let Some(index) = self.lock().selected_document_index() else {
            return false;
        };
        let document = self.lock().snapshot.documents[index].clone();
        match self.manager.delete_script(&document.file) {
            Ok(()) => {
                {
                    let mut state = self.lock();
                    state.snapshot.documents.remove(index);
                    state.snapshot.selected_script_id = state
                        .snapshot
                        .documents
                        .first()
                        .map(|document| document.file.identifier.clone());
                }
                if let Some(handler) = &self.on_script_deleted {
                    handler(&document.file);
                }
                self.publish();
                self.synchronize_language_service();
                true
            }
            Err(error) => {
                self.record_failure(&error.to_string(), index);
                false
            }
        }
    }

    /// Swift `private func persist(scriptAt index:) -> Bool`.
    fn persist_script_at(&self, index: usize) -> bool {
        let (url, source_text, source_buffer, edit_revision, identifier) = {
            let state = self.lock();
            if index >= state.snapshot.documents.len() {
                return false;
            }
            let document = &state.snapshot.documents[index];
            if !document.is_dirty {
                return true;
            }
            (
                document.file.url.clone(),
                document.source.string_value(),
                document.source.clone(),
                document.edit_revision,
                document.file.identifier.clone(),
            )
        };
        match self.manager.write_source(&source_text, &url) {
            Ok(()) => {
                {
                    let mut state = self.lock();
                    state.set_saved_source(index, source_buffer);
                    state.snapshot.documents[index].saved_revision = edit_revision;
                }
                self.publish();
                let manager = self.manager.clone();
                spawn_background("script-did-save-language-source", move || {
                    manager.did_save_language_source(&identifier);
                });
                true
            }
            Err(error) => {
                self.record_failure(&error.to_string(), index);
                false
            }
        }
    }

    // MARK: - Compilation

    /// Swift `public func compileSelected()`.
    pub fn compile_selected(&self) {
        let Some(script_id) = self.lock().snapshot.selected_script_id.clone() else {
            return;
        };
        self.compile(&script_id);
    }

    /// Swift `public func cancelSelectedBuild()`.
    pub fn cancel_selected_build(&self) {
        let Some(index) = self.lock().selected_document_index() else {
            return;
        };
        let (script_id, display_name, is_building) = {
            let state = self.lock();
            let document = &state.snapshot.documents[index];
            (
                document.file.identifier.clone(),
                document.file.display_name.clone(),
                document.build_state.is_building(),
            )
        };
        if !is_building {
            return;
        }
        self.manager.cancel_build(&script_id);
        {
            let mut state = self.lock();
            state.snapshot.documents[index].output = format!("Cancelling {display_name}.swift…");
        }
        self.publish();
    }

    /// Swift `public func setProjectTrusted(_ trusted: Bool)`.
    pub fn set_project_trusted(&self, trusted: bool) {
        match self.manager.set_project_trusted(trusted) {
            Ok(()) => {
                let trust_state = self.manager.project_trust_state();
                {
                    let mut state = self.lock();
                    state.snapshot.trust_state = trust_state;
                    state.snapshot.trust_warning = None;
                    if !trusted {
                        let message = ScriptProjectTrustError::ExecutionBlocked.to_string();
                        for document in state.snapshot.documents.iter_mut() {
                            if !document.is_project_source {
                                document.build_state = ScriptDocumentBuildState::Blocked {
                                    revision: document.edit_revision,
                                    message: message.clone(),
                                };
                            }
                        }
                    }
                }
                self.publish();
            }
            Err(error) => {
                {
                    let mut state = self.lock();
                    state.snapshot.trust_warning = Some(error.to_string());
                }
                self.publish();
            }
        }
    }

    /// Swift `public func compile(scriptID:)`.
    pub fn compile(&self, script_id: &str) {
        let Some(index) = self.lock().document_index(script_id) else {
            return;
        };
        if self.lock().snapshot.documents[index].is_project_source {
            return;
        }
        if !self.persist_script_at(index) {
            return;
        }
        let (file, revision) = {
            let mut state = self.lock();
            let document = &state.snapshot.documents[index];
            let file = document.file.clone();
            let revision = document.edit_revision;
            let display_name = document.file.display_name.clone();
            state.snapshot.documents[index].build_state =
                ScriptDocumentBuildState::Building(revision);
            state.snapshot.documents[index].output = format!("Compiling {}.swift…", display_name);
            (file, revision)
        };
        self.publish();

        let source_url = file.url.clone();
        let owned_script_id = script_id.to_string();
        let weak = self.self_weak.clone();
        let handler: CompilationStatusHandler = Arc::new(move |status| {
            let Some(model) = weak.upgrade() else {
                return;
            };
            let mut loaded = false;
            let mut failure: Option<String> = None;
            {
                let mut state = model.lock();
                let Some(current_index) = state.document_index(&owned_script_id) else {
                    return;
                };
                match status {
                    CompilationStatus::Succeeded => {
                        state.snapshot.documents[current_index].build_state =
                            ScriptDocumentBuildState::Succeeded(revision);
                        state.snapshot.documents[current_index].loaded_revision = Some(revision);
                        state.snapshot.documents[current_index].output =
                            format!("Compiled and reloaded {}.swift", file.display_name);
                        loaded = true;
                    }
                    CompilationStatus::Cancelled => {
                        state.snapshot.documents[current_index].build_state =
                            ScriptDocumentBuildState::Cancelled(revision);
                        state.snapshot.documents[current_index].output =
                            "Build cancelled.".to_string();
                    }
                    CompilationStatus::Blocked { message } => {
                        state.snapshot.documents[current_index].build_state =
                            ScriptDocumentBuildState::Blocked {
                                revision,
                                message: message.clone(),
                            };
                        state.snapshot.documents[current_index].output = message;
                    }
                    CompilationStatus::Failed { message } => {
                        state.snapshot.documents[current_index].build_state =
                            ScriptDocumentBuildState::Failed {
                                revision,
                                message: message.clone(),
                            };
                        state.snapshot.documents[current_index].output = message.clone();
                        failure = Some(message);
                    }
                    CompilationStatus::Compiling | CompilationStatus::Idle => {}
                }
            }
            if loaded && let Some(handler) = &model.on_script_loaded {
                handler(&file);
            }
            if let Some(message) = failure
                && let Some(handler) = &model.on_build_failed
            {
                handler(&file, &message);
            }
            model.publish();
        });
        DynamicScriptManager::compile_and_load(&self.manager, script_id, &source_url, handler);
    }

    /// Swift `public func markAllBuildsStarted()`.
    pub fn mark_all_builds_started(&self) {
        {
            let mut state = self.lock();
            let allows_execution = state.snapshot.trust_state.allows_execution();
            let blocked_message = ScriptProjectTrustError::ExecutionBlocked.to_string();
            for document in state.snapshot.documents.iter_mut() {
                if document.is_project_source {
                    continue;
                }
                let revision = document.saved_revision;
                document.build_state = if allows_execution {
                    ScriptDocumentBuildState::Building(revision)
                } else {
                    ScriptDocumentBuildState::Blocked {
                        revision,
                        message: blocked_message.clone(),
                    }
                };
            }
        }
        self.publish();
    }

    /// Swift `public func recordBuildResult(scriptID:status:)`.
    pub fn record_build_result(&self, script_id: &str, status: CompilationStatus) {
        {
            let mut state = self.lock();
            let Some(index) = state.document_index(script_id) else {
                return;
            };
            let revision = match &state.snapshot.documents[index].build_state {
                ScriptDocumentBuildState::Building(requested_revision) => *requested_revision,
                _ => state.snapshot.documents[index].saved_revision,
            };
            match status {
                CompilationStatus::Succeeded => {
                    state.snapshot.documents[index].build_state =
                        ScriptDocumentBuildState::Succeeded(revision);
                    state.snapshot.documents[index].loaded_revision = Some(revision);
                    state.snapshot.documents[index].output = format!(
                        "Compiled and reloaded {}.swift",
                        state.snapshot.documents[index].file.display_name
                    );
                }
                CompilationStatus::Cancelled => {
                    state.snapshot.documents[index].build_state =
                        ScriptDocumentBuildState::Cancelled(revision);
                    state.snapshot.documents[index].output = "Build cancelled.".to_string();
                }
                CompilationStatus::Blocked { message } => {
                    state.snapshot.documents[index].build_state =
                        ScriptDocumentBuildState::Blocked {
                            revision,
                            message: message.clone(),
                        };
                    state.snapshot.documents[index].output = message;
                }
                CompilationStatus::Failed { message } => {
                    state.snapshot.documents[index].build_state =
                        ScriptDocumentBuildState::Failed {
                            revision,
                            message: message.clone(),
                        };
                    state.snapshot.documents[index].output = message;
                }
                CompilationStatus::Compiling => {
                    state.snapshot.documents[index].build_state =
                        ScriptDocumentBuildState::Building(revision);
                }
                CompilationStatus::Idle => {
                    state.snapshot.documents[index].build_state = ScriptDocumentBuildState::Idle;
                }
            }
        }
        self.publish();
    }

    /// Swift `public func clearSelectedOutput()`.
    pub fn clear_selected_output(&self) {
        {
            let mut state = self.lock();
            let Some(index) = state.selected_document_index() else {
                return;
            };
            state.snapshot.documents[index].output.clear();
        }
        self.publish();
    }

    /// Swift `public func setSelectedOutput(_ message:, marksBuildFailed: Bool = false)`.
    pub fn set_selected_output(&self, message: &str, marks_build_failed: bool) {
        {
            let mut state = self.lock();
            let Some(index) = state.selected_document_index() else {
                return;
            };
            state.snapshot.documents[index].output = message.to_string();
            if marks_build_failed {
                let revision = state.snapshot.documents[index].edit_revision;
                state.snapshot.documents[index].build_state = ScriptDocumentBuildState::Failed {
                    revision,
                    message: message.to_string(),
                };
            }
        }
        self.publish();
    }

    /// The Swift `marksBuildFailed: Bool = false` default.
    pub fn set_selected_output_with_defaults(&self, message: &str) {
        self.set_selected_output(message, false);
    }

    /// Swift `public func dismissLanguageServiceMessage()`.
    pub fn dismiss_language_service_message(&self) {
        {
            let mut state = self.lock();
            if !matches!(
                state.snapshot.language_service_state,
                ScriptLanguageServiceState::Unavailable(_)
            ) {
                return;
            }
            state.snapshot.is_language_service_message_dismissed = true;
        }
        self.publish();
    }

    // MARK: - External changes

    /// Swift `public func resolveSelectedExternalChange(useDiskVersion:)`.
    pub fn resolve_selected_external_change(&self, use_disk_version: bool) {
        let Some(index) = self.lock().selected_document_index() else {
            return;
        };
        let document = self.lock().snapshot.documents[index].clone();
        if document.external_change == ScriptExternalChangeState::None {
            return;
        }
        let mut deleted_file: Option<ScriptFile> = None;
        let outcome: Result<(), String> = (|| {
            let mut state = self.lock();
            match &document.external_change {
                ScriptExternalChangeState::None => {}
                ScriptExternalChangeState::ModifiedOnDisk(disk_source) => {
                    if use_disk_version {
                        state.adopt_disk_source(disk_source, index);
                    } else {
                        self.manager
                            .write_source(&document.source.string_value(), &document.file.url)
                            .map_err(|error| error.to_string())?;
                        state.set_saved_source(index, document.source.clone());
                        state.snapshot.documents[index].saved_revision = document.edit_revision;
                        state.snapshot.documents[index].external_change =
                            ScriptExternalChangeState::None;
                    }
                }
                ScriptExternalChangeState::DeletedOnDisk => {
                    if use_disk_version {
                        self.manager.unload(&document.file.identifier);
                        state.snapshot.documents.remove(index);
                        state.snapshot.selected_script_id = state
                            .snapshot
                            .documents
                            .first()
                            .map(|document| document.file.identifier.clone());
                        deleted_file = Some(document.file.clone());
                    } else {
                        let parent = document
                            .file
                            .url
                            .parent()
                            .map(|parent| parent.to_path_buf())
                            .unwrap_or_else(|| document.file.url.clone());
                        std::fs::create_dir_all(&parent).map_err(|error| error.to_string())?;
                        self.manager
                            .write_source(&document.source.string_value(), &document.file.url)
                            .map_err(|error| error.to_string())?;
                        state.set_saved_source(index, document.source.clone());
                        state.snapshot.documents[index].saved_revision = document.edit_revision;
                        state.snapshot.documents[index].external_change =
                            ScriptExternalChangeState::None;
                    }
                }
            }
            Ok(())
        })();
        match outcome {
            Ok(()) => {
                if let Some(file) = deleted_file
                    && let Some(handler) = &self.on_script_deleted
                {
                    handler(&file);
                }
                self.publish();
                self.synchronize_language_service();
            }
            Err(message) => {
                self.record_failure(&message, index);
            }
        }
    }

    /// Swift `func refreshFromDisk()`.
    pub fn refresh_from_disk(&self) {
        let mut deleted_files: Vec<ScriptFile> = Vec::new();
        let outcome: Result<(bool, bool), String> = (|| {
            let mut state = self.lock();
            let disk_files = self
                .manager
                .scan_script_files()
                .map_err(|error| error.to_string())?;
            let files_by_id: BTreeMap<String, ScriptFile> = disk_files
                .iter()
                .map(|file| (file.identifier.clone(), file.clone()))
                .collect();
            let existing_ids: BTreeSet<String> = state
                .snapshot
                .documents
                .iter()
                .map(|document| document.file.identifier.clone())
                .collect();
            let mut did_change = false;
            let mut needs_language_refresh = false;

            for index in (0..state.snapshot.documents.len()).rev() {
                let document = state.snapshot.documents[index].clone();
                if document.is_project_source {
                    let change = self.project_source_change(&document);
                    let adopted_modified = match &change {
                        ScriptExternalChangeState::ModifiedOnDisk(source) if !document.is_dirty => {
                            Some(source.clone())
                        }
                        _ => None,
                    };
                    if let Some(source) = adopted_modified {
                        state.adopt_disk_source(&source, index);
                        did_change = true;
                        needs_language_refresh = true;
                    } else if state.snapshot.documents[index].external_change != change {
                        state.snapshot.documents[index].external_change = change;
                        did_change = true;
                    }
                    continue;
                }
                let Some(disk_file) = files_by_id.get(&document.file.identifier).cloned() else {
                    if document.is_dirty {
                        if state.snapshot.documents[index].external_change
                            != ScriptExternalChangeState::DeletedOnDisk
                        {
                            state.snapshot.documents[index].external_change =
                                ScriptExternalChangeState::DeletedOnDisk;
                            did_change = true;
                        }
                    } else {
                        self.manager.unload(&document.file.identifier);
                        state.snapshot.documents.remove(index);
                        deleted_files.push(document.file.clone());
                        did_change = true;
                        needs_language_refresh = true;
                    }
                    continue;
                };

                if disk_file != document.file {
                    state.snapshot.documents[index].file = disk_file.clone();
                    did_change = true;
                    needs_language_refresh = true;
                }
                let disk_source = self
                    .manager
                    .read_source(&disk_file.url)
                    .map_err(|error| error.to_string())?;
                if disk_source != document.saved_source.string_value() {
                    if document.is_dirty {
                        let change = ScriptExternalChangeState::ModifiedOnDisk(disk_source);
                        if state.snapshot.documents[index].external_change != change {
                            state.snapshot.documents[index].external_change = change;
                            did_change = true;
                        }
                    } else {
                        state.adopt_disk_source(&disk_source, index);
                        did_change = true;
                        needs_language_refresh = true;
                    }
                } else if state.snapshot.documents[index].external_change
                    != ScriptExternalChangeState::None
                {
                    state.snapshot.documents[index].external_change =
                        ScriptExternalChangeState::None;
                    did_change = true;
                }
            }

            for file in &disk_files {
                if !existing_ids.contains(&file.identifier) {
                    let source = self
                        .manager
                        .read_source(&file.url)
                        .map_err(|error| error.to_string())?;
                    let mut document =
                        ScriptWorkspaceDocument::new(file.clone(), TextBuffer::new(&source));
                    document.output =
                        format!("Discovered external script {}.swift", file.display_name);
                    state.snapshot.documents.push(document);
                    did_change = true;
                    needs_language_refresh = true;
                }
            }

            if !did_change {
                return Ok((false, false));
            }
            state.sort_documents();
            let still_selected = state
                .snapshot
                .selected_script_id
                .as_ref()
                .and_then(|id| {
                    state
                        .snapshot
                        .documents
                        .iter()
                        .find(|document| document.file.identifier == *id)
                })
                .is_some();
            if !still_selected {
                state.snapshot.selected_script_id = state
                    .snapshot
                    .documents
                    .first()
                    .map(|document| document.file.identifier.clone());
            }
            Ok((did_change, needs_language_refresh))
        })();

        match outcome {
            Ok((did_change, needs_language_refresh)) => {
                if !did_change {
                    return;
                }
                for file in &deleted_files {
                    if let Some(handler) = &self.on_script_deleted {
                        handler(file);
                    }
                }
                self.publish();
                if needs_language_refresh {
                    self.synchronize_language_service();
                }
            }
            Err(message) => {
                {
                    let mut state = self.lock();
                    state.snapshot.trust_warning = Some(format!(
                        "Could not refresh external script changes: {message}"
                    ));
                }
                self.publish();
            }
        }
    }

    // MARK: - Language-service plumbing

    /// Swift `private func synchronizeLanguageService()`.
    fn synchronize_language_service(&self) {
        enum Action {
            Stop,
            Start,
            Restart {
                sources: Vec<ScriptLanguageSource>,
                generation: String,
            },
        }
        let action = {
            let mut state = self.lock();
            if state.language_service_suspended {
                return;
            }
            let wants = self.wants_language_service(&state);
            if !wants {
                state.language_service_generation = new_uuid();
                state.did_start_language_service = false;
                state.snapshot.language_service_state = ScriptLanguageServiceState::Inactive;
                Action::Stop
            } else if !state.did_start_language_service {
                Action::Start
            } else {
                state.snapshot.language_service_state = ScriptLanguageServiceState::Starting;
                state.snapshot.language_service_details = None;
                state.snapshot.is_language_service_message_dismissed = false;
                Action::Restart {
                    sources: state.language_sources(),
                    generation: state.language_service_generation.clone(),
                }
            }
        };
        match action {
            Action::Stop => {
                self.publish();
                self.cancel_language_service_task();
                let manager = self.manager.clone();
                self.spawn_language_service_task(false, move || {
                    manager.stop_language_service();
                });
            }
            Action::Start => self.start_language_service(),
            Action::Restart {
                sources,
                generation,
            } => {
                self.publish();
                let manager = self.manager.clone();
                let weak = self.self_weak.clone();
                self.spawn_language_service_task(true, move || {
                    let outcome: Result<(), String> = (|| {
                        manager
                            .refresh_language_workspace(&sources)
                            .map_err(|error| error.to_string())?;
                        let current: Vec<ScriptLanguageSource> = match weak.upgrade() {
                            Some(model) => model.language_sources_for_restart(&generation),
                            None => Vec::new(),
                        };
                        for source in &current {
                            manager
                                .update_language_source(
                                    &source.file.identifier,
                                    &source.text,
                                    source.revision,
                                )
                                .map_err(|error| error.to_string())?;
                        }
                        Ok(())
                    })();
                    if let Err(message) = outcome
                        && let Some(model) = weak.upgrade()
                    {
                        model.apply_language_service_unavailable(&generation, message);
                    }
                });
            }
        }
    }

    /// Swift `private func applyLanguageServiceState(_:)`.
    fn apply_language_service_state(&self, update: ScriptLanguageServiceUpdate) {
        {
            let mut state = self.lock();
            if update.revision <= state.language_service_revision {
                return;
            }
            state.language_service_revision = update.revision;
            let state_value = update.state;
            let wants = self.wants_language_service(&state);
            state.snapshot.language_service_state = if wants {
                state_value.clone()
            } else {
                ScriptLanguageServiceState::Inactive
            };
            state.snapshot.is_language_service_message_dismissed = false;
            if state_value != ScriptLanguageServiceState::Ready {
                for document in state.snapshot.documents.iter_mut() {
                    document.diagnostics.clear();
                }
            }
        }
        self.publish();
    }

    /// Swift `public func retryLanguageService()`.
    pub fn retry_language_service(&self) {
        {
            let mut state = self.lock();
            state.did_start_language_service = false;
        }
        self.start_language_service();
    }

    /// Swift `configureSwiftToolchain(path:preferencesDirectory:activate:recover:) async throws`.
    pub fn configure_swift_toolchain(
        &self,
        path: Option<&str>,
        preferences_directory: &Path,
        activate: ToolchainTransition,
        recover: ToolchainTransition,
    ) -> Result<(), DynamicScriptManagerError> {
        {
            let mut state = self.lock();
            state.toolchain_activity_generation = new_uuid();
            state.snapshot.toolchain_activity = ScriptToolchainActivity::Selecting;
            state.toolchain_language_intent = Some(ScriptToolchainLanguageIntent {
                suspended: state.language_service_suspended,
                did_suspend: false,
            });
        }
        self.publish();

        let weak = self.self_weak.clone();
        let suspend: ToolchainSuspend = Arc::new(move || {
            let Some(model) = weak.upgrade() else {
                return;
            };
            {
                let mut state = model.lock();
                if let Some(intent) = state.toolchain_language_intent.as_mut() {
                    intent.did_suspend = true;
                }
            }
            model.suspend_language_service();
            model.await_language_service_task();
        });
        let activation = ScriptToolchainActivation::new(suspend, activate, recover);

        match self
            .manager
            .configure_swift_toolchain(path, preferences_directory, &activation)
        {
            Ok(()) => {
                let swift_toolchain = self.manager.swift_toolchain();
                {
                    let mut state = self.lock();
                    state.snapshot.swift_toolchain = swift_toolchain;
                    state.snapshot.language_service_details = None;
                }
                self.finish_toolchain_language_service_change();
                {
                    let mut state = self.lock();
                    state.snapshot.toolchain_activity = ScriptToolchainActivity::Idle;
                }
                self.publish();
                Ok(())
            }
            Err(error) => {
                let swift_toolchain = self.manager.swift_toolchain();
                {
                    let mut state = self.lock();
                    state.snapshot.swift_toolchain = swift_toolchain;
                }
                self.finish_toolchain_language_service_change();
                // Swift: `error is CancellationError ? .installation(.cancelled) : .failed(...)`.
                // There is no `CancellationError` in the Rust port (no async
                // runtime; `DynamicScriptManagerError` has no cancellation
                // case). The crate spells a cancelled step as the message
                // `"cancelled"` (`StepError::Cancelled`), so keep the exact
                // branch shape and value with that spelling.
                let message = error.to_string();
                let activity = if message.eq_ignore_ascii_case("cancelled") {
                    ScriptToolchainActivity::Installation(SwiftToolchainInstallProgress::Cancelled)
                } else {
                    ScriptToolchainActivity::Failed(message)
                };
                {
                    let mut state = self.lock();
                    state.snapshot.toolchain_activity = activity;
                }
                self.publish();
                Err(error)
            }
        }
    }

    /// The Swift `preferencesDirectory: URL = SwiftToolchainPreferences.directory`
    /// default.
    pub fn configure_swift_toolchain_with_defaults(
        &self,
        path: Option<&str>,
        activate: ToolchainTransition,
        recover: ToolchainTransition,
    ) -> Result<(), DynamicScriptManagerError> {
        let directory = SwiftToolchainPreferences::directory();
        self.configure_swift_toolchain(path, &directory, activate, recover)
    }

    /// Swift `private func finishToolchainLanguageServiceChange()`.
    fn finish_toolchain_language_service_change(&self) {
        let is_bound = self.manager.language_plugin.is_bound();
        let should_suspend = {
            let mut state = self.lock();
            let Some(intent) = state.toolchain_language_intent.take() else {
                return;
            };
            if !(intent.did_suspend || intent.suspended != state.language_service_suspended) {
                return;
            }
            intent.suspended || !is_bound
        };
        if should_suspend {
            self.suspend_language_service();
        } else {
            self.start_language_service();
        }
    }

    /// Swift `func beginToolchainActivity(_:) -> UUID`.
    pub fn begin_toolchain_activity(&self, activity: ScriptToolchainActivity) -> String {
        let generation = {
            let mut state = self.lock();
            state.toolchain_activity_generation = new_uuid();
            state.snapshot.toolchain_activity = activity;
            state.toolchain_activity_generation.clone()
        };
        self.publish();
        generation
    }

    /// Swift `func reportToolchainActivity(_:generation:)`.
    pub fn report_toolchain_activity(&self, activity: ScriptToolchainActivity, generation: &str) {
        {
            let mut state = self.lock();
            if state.toolchain_activity_generation.as_str() != generation {
                return;
            }
            state.snapshot.toolchain_activity = activity;
        }
        self.publish();
    }

    /// Swift `private func applyDiagnostics(_:)`.
    fn apply_diagnostics(&self, update: ScriptLanguageDiagnosticUpdate) {
        {
            let mut state = self.lock();
            let Some(index) = state.document_index(&update.script_id) else {
                return;
            };
            if state.snapshot.documents[index].edit_revision != update.source_revision {
                return;
            }
            state.snapshot.documents[index].diagnostics = update.diagnostics;
        }
        self.publish();
    }

    /// The `onDetailsChange` body: revision gate, then publish.
    fn apply_language_service_details(
        &self,
        details: ScriptLanguageServiceDetails,
        generation: &str,
    ) {
        {
            let mut state = self.lock();
            if state.language_service_generation.as_str() != generation {
                return;
            }
            let current_revision = state
                .snapshot
                .language_service_details
                .as_ref()
                .map(|details| details.revision)
                .unwrap_or(0);
            if details.revision < current_revision {
                return;
            }
            state.snapshot.language_service_details = Some(details);
        }
        self.publish();
    }

    fn generation_matches(&self, generation: &str) -> bool {
        self.lock().language_service_generation.as_str() == generation
    }

    /// Swift `MainActor.run` inside `startLanguageService`'s task.
    fn language_sources_for_generation(&self, generation: &str) -> Vec<ScriptLanguageSource> {
        let state = self.lock();
        if state.language_service_generation.as_str() != generation {
            return Vec::new();
        }
        state.language_sources()
    }

    /// Swift `MainActor.run` inside `synchronizeLanguageService`'s task; it also
    /// refreshes `didStartLanguageService = wantsLanguageService`.
    fn language_sources_for_restart(&self, generation: &str) -> Vec<ScriptLanguageSource> {
        let mut state = self.lock();
        if state.language_service_generation.as_str() != generation {
            return Vec::new();
        }
        state.did_start_language_service =
            !state.snapshot.documents.is_empty() || self.project_uses_language;
        state.language_sources()
    }

    /// The `catch` + `MainActor.run` of both language-service tasks.
    fn apply_language_service_unavailable(&self, generation: &str, message: String) {
        {
            let mut state = self.lock();
            if state.language_service_generation.as_str() != generation {
                return;
            }
            state.did_start_language_service = false;
            state.snapshot.language_service_state =
                ScriptLanguageServiceState::Unavailable(message);
        }
        self.publish();
    }

    /// `await languageServiceTask?.value` in the toolchain suspension closure.
    fn await_language_service_task(&self) {
        let done = self
            .lock()
            .language_service_task
            .as_ref()
            .map(|task| task.done.clone());
        if let Some(done) = done {
            while !done.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(1));
            }
        }
    }

    /// `languageServiceTask?.cancel()`.
    fn cancel_language_service_task(&self) {
        let state = self.lock();
        if let Some(task) = &state.language_service_task {
            task.cancel.store(true, Ordering::SeqCst);
        }
    }

    /// Swift `languageServiceTask = Task { ... }`: one named thread per
    /// generation, with an `AtomicBool` cancellation token. When
    /// `wait_for_previous` is set, the new thread first waits for the previous
    /// task's completion, mirroring `await previousTask?.value`.
    fn spawn_language_service_task<F>(&self, wait_for_previous: bool, body: F)
    where
        F: FnOnce() + Send + 'static,
    {
        let (previous, cancel, done) = {
            let mut state = self.lock();
            let previous = if wait_for_previous {
                state.language_service_task.clone()
            } else {
                None
            };
            let cancel = Arc::new(AtomicBool::new(false));
            let done = Arc::new(AtomicBool::new(false));
            state.language_service_task = Some(LanguageServiceTask {
                cancel: cancel.clone(),
                done: done.clone(),
            });
            (previous, cancel, done)
        };
        let _ = std::thread::Builder::new()
            .name("script-language-service".to_string())
            .spawn(move || {
                let _completion = CompletionGuard(done);
                if let Some(previous) = previous {
                    while !previous.done.load(Ordering::SeqCst) {
                        std::thread::sleep(Duration::from_millis(1));
                    }
                }
                if cancel.load(Ordering::SeqCst) {
                    return;
                }
                body();
            });
    }

    // MARK: - Failure recording

    /// Swift `private func recordFailure(_ message:at:)`.
    fn record_failure(&self, message: &str, index: usize) {
        {
            let mut state = self.lock();
            if index >= state.snapshot.documents.len() {
                return;
            }
            let revision = state.snapshot.documents[index].edit_revision;
            state.snapshot.documents[index].build_state = ScriptDocumentBuildState::Failed {
                revision,
                message: message.to_string(),
            };
            state.snapshot.documents[index].output = message.to_string();
        }
        self.publish();
    }

    /// Swift `private func recordWorkspaceFailure(_ message:)`.
    fn record_workspace_failure(&self, message: &str) {
        let Some(index) = self.lock().selected_document_index() else {
            return;
        };
        self.record_failure(message, index);
    }

    // MARK: - Observers

    /// Swift `_registerObserver(_ handler:) -> AnyHashable`. The token is the
    /// crate's `u64` observer token (see `tasks::runner::EditorTasks`).
    pub fn register_observer(&self, handler: Arc<dyn Fn() + Send + Sync>) -> u64 {
        self.observers.register(handler)
    }

    /// Swift `_unregisterObserver(_ token:)`.
    pub fn unregister_observer(&self, token: u64) {
        self.observers.unregister(token);
    }
}

/// Swift `deinit { directoryMonitor.stop() }`.
impl Drop for ScriptWorkspaceModel {
    fn drop(&mut self) {
        self.directory_monitor.stop();
    }
}

// MARK: - Local error & helpers

/// Swift `private enum ScriptWorkspaceError: Error, LocalizedError`.
#[derive(Debug, thiserror::Error)]
enum ScriptWorkspaceError {
    #[error("The created script could not be registered as an asset: {0}")]
    CreatedScriptMissing(String),
}

/// Swift `Task { ... }` for fire-and-forget manager calls (§5.5).
fn spawn_background(name: &'static str, body: impl FnOnce() + Send + 'static) {
    let _ = std::thread::Builder::new()
        .name(name.to_string())
        .spawn(body);
}

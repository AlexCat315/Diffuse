//! Translation of `Editor/Sources/EditorCore/VersionControl/Workspace.swift`.
//!
//! The project's working tree as the editor sees it. Detection, status reads
//! and every operation run synchronously under one serialization lock; results
//! are published as one snapshot. The monitor thread only polls while no
//! operation is in flight.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use cove_system::paths::PathIdentity;
use serde_json::json;

use crate::application::plugins::bundled::BundledPlugins;
use crate::contributions::host::StepPlugins;
use crate::version_control::backend::{VersionControlBackend, VersionControlError};
use crate::version_control::model::{
    VersionControlAvailability, VersionControlChange, VersionControlComparison,
    VersionControlFileState, VersionControlOperation, VersionControlRepository,
    VersionControlSnapshot, VersionControlSystem,
};
use crate::version_control::providers::VersionControlProvider;

struct WorkspaceState {
    snapshot: VersionControlSnapshot,
    backend: Option<Box<dyn VersionControlBackend>>,
}

pub struct EditorVersionControl {
    project_root: PathBuf,
    plugins: StepPlugins,
    state: Mutex<WorkspaceState>,
    operation_lock: Mutex<()>,
    did_change_files: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    observers: Mutex<BTreeMap<u64, Arc<dyn Fn() + Send + Sync>>>,
    next_observer: AtomicU64,
    monitoring: Arc<AtomicBool>,
    monitor_thread: Mutex<Option<JoinHandle<()>>>,
}

impl EditorVersionControl {
    /// The editor's per-machine state under `.cove` is not project content.
    pub const MACHINE_STATE_PATTERNS: [&'static str; 4] = [
        ".cove/observation/",
        ".cove/plugin_authorizations.json",
        ".cove/disabled_bundled_plugins.json",
        ".cove/sourcekit-lsp/",
    ];

    pub fn new(project_root: &Path, plugins: StepPlugins) -> Self {
        EditorVersionControl {
            project_root: PathIdentity::canonical_url(project_root),
            plugins,
            state: Mutex::new(WorkspaceState {
                snapshot: VersionControlSnapshot::new(),
                backend: None,
            }),
            operation_lock: Mutex::new(()),
            did_change_files: Mutex::new(None),
            observers: Mutex::new(BTreeMap::new()),
            next_observer: AtomicU64::new(0),
            monitoring: Arc::new(AtomicBool::new(false)),
            monitor_thread: Mutex::new(None),
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, WorkspaceState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn project_root(&self) -> &Path {
        &self.project_root
    }

    pub fn snapshot(&self) -> VersionControlSnapshot {
        self.state().snapshot.clone()
    }

    pub fn set_did_change_files(&self, handler: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self
            .did_change_files
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = handler;
    }

    // MARK: Lifecycle

    /// Polls the working tree while the editor runs; Lore's scan walks the
    /// disk, so it polls less often.
    pub fn start_monitoring(self: &Arc<Self>) {
        if self.monitoring.swap(true, Ordering::SeqCst) {
            return;
        }
        let control = self.monitoring.clone();
        let workspace = Arc::downgrade(self);
        let handle = std::thread::Builder::new()
            .name("com.cove.editor.version-control-monitor".to_string())
            .spawn(move || {
                while control.load(Ordering::SeqCst) {
                    let Some(workspace) = workspace.upgrade() else {
                        return;
                    };
                    if workspace.snapshot().operation.is_none() {
                        workspace.refresh();
                    }
                    let seconds =
                        if workspace.snapshot().availability.repository().is_some_and(
                            |repository| repository.system == VersionControlSystem::lore(),
                        ) {
                            15
                        } else {
                            4
                        };
                    for _ in 0..seconds * 10 {
                        if !control.load(Ordering::SeqCst) {
                            return;
                        }
                        std::thread::sleep(Duration::from_millis(100));
                    }
                }
            })
            .ok();
        *self
            .monitor_thread
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = handle;
    }

    pub fn stop_monitoring(&self) {
        self.monitoring.store(false, Ordering::SeqCst);
        let handle = self
            .monitor_thread
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .take();
        if let Some(handle) = handle {
            let _ = handle.join();
        }
    }

    // MARK: Operations

    /// Re-detects the repository, then reads status, history, branches and locks.
    pub fn refresh(&self) {
        self.run_serialized(None, |_| Ok(()));
    }

    pub fn stage(&self, changes: &[VersionControlChange]) {
        let paths: Vec<String> = changes
            .iter()
            .flat_map(|change| [change.original_path.clone(), Some(change.path.clone())])
            .flatten()
            .collect();
        self.run_serialized(Some(VersionControlOperation::Staging), |backend| {
            backend
                .stage(&paths)
                .map_err(|error| error.error_description())
        });
    }

    pub fn unstage(&self, changes: &[VersionControlChange]) {
        let paths: Vec<String> = changes.iter().map(|change| change.path.clone()).collect();
        self.run_serialized(Some(VersionControlOperation::Unstaging), |backend| {
            backend
                .unstage(&paths)
                .map_err(|error| error.error_description())
        });
    }

    pub fn discard(&self, changes: &[VersionControlChange]) {
        let _serial = self
            .operation_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.publish(|snapshot| snapshot.operation = Some(VersionControlOperation::Discarding));
        let result = {
            let state = self.state();
            state
                .backend
                .as_ref()
                .ok_or_else(|| unsupported_working_tree())
                .and_then(|backend| {
                    backend
                        .discard(changes)
                        .map_err(|error| error.error_description())
                })
        };
        if result.is_ok() {
            self.notify_files_changed();
        }
        self.finish_operation(result);
    }

    /// Commits staged changes, or every change when nothing is staged.
    pub fn commit(&self, message: &str) -> bool {
        let message = message.trim();
        if message.is_empty() {
            self.publish(|snapshot| snapshot.error = Some("Enter a commit message.".to_string()));
            return false;
        }
        let stage_all = self.snapshot().staged().is_empty();
        self.run_serialized(Some(VersionControlOperation::Committing), |backend| {
            backend
                .commit(message, stage_all)
                .map_err(|error| error.error_description())
        })
    }

    pub fn pull(&self) {
        let _serial = self
            .operation_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.publish(|snapshot| snapshot.operation = Some(VersionControlOperation::Pulling));
        let result = self
            .state()
            .backend
            .as_ref()
            .ok_or_else(|| unsupported_working_tree())
            .and_then(|backend| backend.pull().map_err(|error| error.error_description()));
        if result.is_ok() {
            self.notify_files_changed();
        }
        self.finish_operation(result);
    }

    pub fn push(&self) {
        let _serial = self
            .operation_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.publish(|snapshot| snapshot.operation = Some(VersionControlOperation::Pushing));
        let result = self
            .state()
            .backend
            .as_ref()
            .ok_or_else(|| unsupported_working_tree())
            .and_then(|backend| backend.push().map_err(|error| error.error_description()));
        self.finish_operation(result);
    }

    pub fn switch_branch(&self, name: &str) {
        let _serial = self
            .operation_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.publish(|snapshot| {
            snapshot.operation = Some(VersionControlOperation::SwitchingBranch)
        });
        let result = self
            .state()
            .backend
            .as_ref()
            .ok_or_else(|| unsupported_working_tree())
            .and_then(|backend| {
                backend
                    .switch_branch(name)
                    .map_err(|error| error.error_description())
            });
        if result.is_ok() {
            self.notify_files_changed();
        }
        self.finish_operation(result);
    }

    pub fn create_branch(&self, name: &str) {
        let name = name.trim();
        self.run_serialized(Some(VersionControlOperation::CreatingBranch), |backend| {
            backend
                .create_branch(name)
                .map_err(|error| error.error_description())
        });
    }

    pub fn set_locked(&self, locked: bool, paths: &[String]) {
        self.run_serialized(Some(VersionControlOperation::Locking), |backend| {
            backend
                .set_locked(locked, paths)
                .map_err(|error| error.error_description())
        });
    }

    /// Shows `change` in the editor's diff tab and reads its diff.
    pub fn compare(&self, change: &VersionControlChange) {
        self.publish(|snapshot| {
            snapshot.comparison = Some(VersionControlComparison::new(change.clone()));
        });
        self.load_comparison();
    }

    pub fn end_comparison(&self) {
        self.publish(|snapshot| snapshot.comparison = None);
    }

    fn load_comparison(&self) {
        let state = self.state();
        let Some(comparison) = state.snapshot.comparison.clone() else {
            return;
        };
        if !comparison.is_current {
            return;
        }
        let Some(backend) = state.backend.as_ref() else {
            return;
        };
        let text = backend
            .diff(&comparison.change)
            .unwrap_or_else(|error| error.error_description());
        drop(state);
        let unchanged = self
            .state()
            .snapshot
            .comparison
            .as_ref()
            .is_some_and(|current| current.change == comparison.change);
        if !unchanged {
            return;
        }
        self.publish(|snapshot| {
            if let Some(comparison) = snapshot.comparison.as_mut() {
                comparison.diff = Some(text);
            }
        });
    }

    /// The unified diff of one change; failures read as an explanation.
    pub fn diff(&self, change: &VersionControlChange) -> String {
        let state = self.state();
        let Some(backend) = state.backend.as_ref() else {
            return String::new();
        };
        backend
            .diff(change)
            .unwrap_or_else(|error| error.error_description())
    }

    /// Creates a repository for the project directory. Lore needs its server URL.
    pub fn initialize(&self, system: VersionControlSystem, lore_remote: Option<&str>) {
        let _serial = self
            .operation_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        self.publish(|snapshot| snapshot.operation = Some(VersionControlOperation::Initializing));
        let result = (|| {
            let plugin = self
                .plugins
                .plugin_for(&system, &self.project_root)
                .map_err(|error| error.to_string())?;
            plugin
                .perform(
                    &json!({ "op": "init", "remote": lore_remote.unwrap_or("") }),
                    None,
                    crate::contributions::host::StepPlugin::WINDOW,
                    None,
                    None,
                )
                .map_err(|error| error.to_string())?;
            let ignore_file = VersionControlProvider::provider_for(&system)
                .map(|provider| provider.contribution.ignore_file)
                .unwrap_or_else(|| ".gitignore".to_string());
            Self::ignore_machine_state(&self.project_root, &ignore_file)
                .map_err(|error| error.to_string())?;
            self.state().backend = None;
            Ok(())
        })();
        self.finish_operation(result);
    }

    /// The editor's per-machine state under `.cove` (observation logs, plugin
    /// approvals and preferences) is not project content. Existing rules are kept.
    pub fn ignore_machine_state(root: &Path, file: &str) -> std::io::Result<()> {
        let url = root.join(file);
        let existing = std::fs::read_to_string(&url).unwrap_or_default();
        let lines: BTreeSet<&str> = existing
            .split('\n')
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .collect();
        let missing: Vec<&str> = Self::MACHINE_STATE_PATTERNS
            .iter()
            .copied()
            .filter(|pattern| !lines.contains(pattern))
            .collect();
        if missing.is_empty() {
            return Ok(());
        }
        let mut text = existing;
        if !text.is_empty() && !text.ends_with('\n') {
            text.push('\n');
        }
        text.push_str("# Cove Studio machine-local state\n");
        text.push_str(&missing.join("\n"));
        text.push('\n');
        AtomicFile::write(text.as_bytes(), &url, Access::Inherit)
    }

    // MARK: Paths

    /// The project-relative path of a repository path, when it lies in the project.
    pub fn project_path(&self, repository_path: &str) -> Option<String> {
        let root = self
            .snapshot()
            .availability
            .repository()
            .map(|repository| repository.root.clone())?;
        let absolute = PathIdentity::canonical_url(&root.join(repository_path));
        let base = if self.project_root.to_string_lossy().ends_with('/') {
            self.project_root.to_string_lossy().into_owned()
        } else {
            format!("{}/", self.project_root.to_string_lossy())
        };
        let absolute = absolute.to_string_lossy();
        absolute.strip_prefix(&base).map(ToString::to_string)
    }

    /// Project-relative paths with their working-tree state, for file trees.
    /// Unstaged state wins over staged so pending edits stay visible.
    pub fn project_file_states(&self) -> BTreeMap<String, VersionControlFileState> {
        let mut changes = self.snapshot().status.changes;
        changes.sort_by_key(|change| change.is_staged);
        let mut result = BTreeMap::new();
        for change in changes {
            if let Some(path) = self.project_path(&change.path) {
                result.insert(path, change.state);
            }
        }
        result
    }

    // MARK: Execution

    fn run_serialized(
        &self,
        operation: Option<VersionControlOperation>,
        body: impl FnOnce(&dyn VersionControlBackend) -> Result<(), String>,
    ) -> bool {
        let _serial = self
            .operation_lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(operation) = operation {
            self.publish(|snapshot| snapshot.operation = Some(operation));
        }
        let result = {
            let state = self.state();
            state
                .backend
                .as_ref()
                .ok_or_else(unsupported_working_tree)
                .and_then(|backend| body(backend.as_ref()))
        };
        self.finish_operation(result)
    }

    fn finish_operation(&self, result: Result<(), String>) -> bool {
        match result {
            Ok(()) => {
                self.publish(|snapshot| snapshot.error = None);
                self.reload();
                self.publish(|snapshot| snapshot.operation = None);
                true
            }
            Err(error) => {
                self.publish(|snapshot| snapshot.error = Some(error));
                self.reload();
                self.publish(|snapshot| snapshot.operation = None);
                false
            }
        }
    }

    fn reload(&self) {
        let installed = self.plugins.installed_systems();
        let disabled: BTreeSet<VersionControlSystem> =
            BundledPlugins::disabled(&self.project_root, false)
                .unwrap_or_default()
                .into_iter()
                .filter_map(|id| {
                    VersionControlProvider::bundled()
                        .iter()
                        .find(|provider| provider.plugin_id() == id)
                        .map(|provider| provider.system.clone())
                })
                .collect();
        self.publish(|snapshot| snapshot.disabled_systems = disabled.clone());
        let providers = self.plugins.runtime.version_control_providers();
        let repository = VersionControlProvider::repository_containing(
            &self.project_root,
            &disabled,
            Some(&providers),
        );
        let Some(repository) = repository else {
            self.state().backend = None;
            self.publish(|snapshot| {
                let error = snapshot.error.clone();
                *snapshot = VersionControlSnapshot::new();
                snapshot.availability = VersionControlAvailability::NoRepository;
                snapshot.installed_systems = installed.clone();
                snapshot.disabled_systems = disabled.clone();
                snapshot.error = error;
            });
            return;
        };
        {
            let needs_backend = {
                let state = self.state();
                state
                    .backend
                    .as_ref()
                    .is_none_or(|backend| backend.repository() != &repository)
            };
            if needs_backend {
                match self.plugins.backend(&repository) {
                    Ok(backend) => self.state().backend = Some(backend),
                    Err(VersionControlError::ToolMissing(_)) => {
                        self.state().backend = None;
                    }
                    Err(error) => {
                        self.state().backend = None;
                        self.publish(|snapshot| {
                            *snapshot = VersionControlSnapshot::new();
                            snapshot.availability =
                                VersionControlAvailability::Ready(repository.clone());
                            snapshot.installed_systems = installed.clone();
                            snapshot.disabled_systems = disabled.clone();
                            snapshot.error = Some(error.error_description());
                        });
                        return;
                    }
                }
            }
        }
        let state = self.state();
        let Some(backend) = state.backend.as_ref() else {
            drop(state);
            self.publish(|snapshot| {
                *snapshot = VersionControlSnapshot::new();
                snapshot.availability =
                    VersionControlAvailability::ToolMissing(repository.system.clone());
                snapshot.installed_systems = installed.clone();
                snapshot.disabled_systems = disabled.clone();
            });
            return;
        };
        let status = backend.status();
        let history = backend.history(50);
        let branches = backend.branches();
        let locks = backend.locks();
        drop(state);
        match (status, history, branches, locks) {
            (Ok(status), Ok(history), Ok(branches), Ok(locks)) => {
                self.publish(|snapshot| {
                    snapshot.availability = VersionControlAvailability::Ready(repository.clone());
                    snapshot.installed_systems = installed.clone();
                    snapshot.status = status.clone();
                    snapshot.history = history;
                    snapshot.branches = branches;
                    snapshot.locks = locks;
                    if let Some(comparison) = snapshot.comparison.clone() {
                        snapshot.comparison = Some(Self::follow(&comparison, &status.changes));
                    }
                });
                self.load_comparison();
            }
            (error, _, _, _) => {
                let message = match error {
                    Err(error) => error.error_description(),
                    Ok(_) => String::new(),
                };
                self.publish(|snapshot| {
                    snapshot.availability = VersionControlAvailability::Ready(repository.clone());
                    snapshot.error = Some(message);
                });
            }
        }
    }

    /// The compared file in the latest status: its own area first, then the
    /// other, so staging or unstaging it keeps the tab on the same file.
    pub fn follow(
        comparison: &VersionControlComparison,
        changes: &[VersionControlChange],
    ) -> VersionControlComparison {
        let path = &comparison.change.path;
        let matched = changes
            .iter()
            .find(|change| &change.path == path && change.is_staged == comparison.change.is_staged)
            .or_else(|| changes.iter().find(|change| &change.path == path));
        let Some(change) = matched else {
            let mut gone = comparison.clone();
            gone.is_current = false;
            return gone;
        };
        let diff = if *change == comparison.change {
            comparison.diff.clone()
        } else {
            None
        };
        VersionControlComparison {
            change: change.clone(),
            diff,
            is_current: true,
        }
    }

    fn notify_files_changed(&self) {
        if let Some(handler) = self
            .did_change_files
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
        {
            handler();
        }
    }

    fn publish(&self, change: impl FnOnce(&mut VersionControlSnapshot)) {
        let changed = {
            let mut state = self.state();
            let mut next = state.snapshot.clone();
            change(&mut next);
            if next == state.snapshot {
                false
            } else {
                state.snapshot = next;
                true
            }
        };
        if changed {
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
}

fn unsupported_working_tree() -> String {
    "This project is not in a Git or Lore working tree.".to_string()
}

impl VersionControlAvailability {
    fn repository(&self) -> Option<&VersionControlRepository> {
        match self {
            VersionControlAvailability::Ready(repository) => Some(repository),
            _ => None,
        }
    }
}

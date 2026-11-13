//! `Editor/Sources/EditorCore/Scripting/Dynamic/DynamicScriptBuildCoordinator.swift`.
//!
//! D1 rewrite: scripts are Rust cdylibs built by `cargo`, so the compiler is the
//! engine's [`ScriptCompiler`] and the loader is [`ScriptLoader`]. The Swift
//! actor is a shared struct whose mutable state sits behind a `Mutex`; the
//! compiler runs while that lock is released, exactly like Swift's detached
//! compilation task, so another thread can publish a newer request or cancel the
//! running one.
//!
//! A script build compiles the project's `Scripts/` crate. Cargo produces one
//! cdylib for the whole crate, and the loader selects the script by identifier;
//! registration still happens once per identifier so scene bindings keep
//! Swift's identifier granularity.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use cove_logging::{Level, LogEvent, LogSystem};
use diffuse_script::dynamic_script::script_compiler::{
    ScriptCompilationCancellationToken, ScriptCompileError, ScriptCompiler,
};
use diffuse_script::dynamic_script::script_loader::{ScriptFactory, ScriptLoadError, ScriptLoader};
use diffuse_script::{Script, ScriptDefinition, ScriptRuntime};

use crate::scripting::toolchain::resolution::SwiftToolchainError;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DynamicScriptCompilationArtifact {
    pub output_path: String,
    pub stdout: String,
    pub stderr: String,
}

pub trait DynamicScriptCompiling: Send + Sync {
    fn compile(
        &self,
        source_path: &str,
        script_id: &str,
        cancellation: &ScriptCompilationCancellationToken,
    ) -> Result<DynamicScriptCompilationArtifact, ScriptCompileError>;
}

/// Swift's `SwiftScriptCompilerDriver`; D1 drives the engine's cargo compiler.
/// The `Swift*` name is kept because the script pipeline and persisted toolchain
/// preferences refer to the toolchain under it.
#[derive(Clone, Debug)]
pub struct SwiftScriptCompilerDriver {
    pub compiler: ScriptCompiler,
}

impl SwiftScriptCompilerDriver {
    pub fn new(compiler: ScriptCompiler) -> Self {
        Self { compiler }
    }
}

impl DynamicScriptCompiling for SwiftScriptCompilerDriver {
    fn compile(
        &self,
        source_path: &str,
        script_id: &str,
        cancellation: &ScriptCompilationCancellationToken,
    ) -> Result<DynamicScriptCompilationArtifact, ScriptCompileError> {
        let result = self
            .compiler
            .compile(source_path, script_id, Some(cancellation))?;
        Ok(DynamicScriptCompilationArtifact {
            output_path: result.output_path,
            stdout: result.stdout,
            stderr: result.stderr,
        })
    }
}

pub trait DynamicScriptLibraryLoading: Send + Sync {
    fn load_factory(
        &self,
        script_id: &str,
        library_path: &str,
    ) -> Result<ScriptFactory, ScriptLoadError>;
    fn definition(&self, _script_id: &str) -> ScriptDefinition {
        ScriptDefinition::default()
    }
    fn unload(&self, script_id: &str);
}

impl DynamicScriptLibraryLoading for ScriptLoader {
    fn load_factory(
        &self,
        script_id: &str,
        library_path: &str,
    ) -> Result<ScriptFactory, ScriptLoadError> {
        ScriptLoader::load_factory(self, script_id, library_path)
    }

    fn definition(&self, script_id: &str) -> ScriptDefinition {
        ScriptLoader::definition(self, script_id)
    }

    fn unload(&self, script_id: &str) {
        ScriptLoader::unload(self, script_id);
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DynamicScriptBuildOutcome {
    Succeeded { stdout: String, stderr: String },
    Failed { message: String },
    Cancelled,
    Superseded,
}

pub type DynamicScriptCompilerHandle = Arc<dyn DynamicScriptCompiling>;

#[derive(Clone)]
struct ActiveCompilation {
    request_id: u64,
    cancellation: ScriptCompilationCancellationToken,
}

struct CoordinatorInner {
    compiler: DynamicScriptCompilerHandle,
    is_changing_compiler: bool,
    next_request_id: u64,
    newest_request_by_script_id: BTreeMap<String, u64>,
    active_compilations: BTreeMap<String, ActiveCompilation>,
    explicitly_cancelled_request_ids: BTreeSet<u64>,
    loaded_artifact_paths: BTreeMap<String, String>,
    registered_identifiers: BTreeMap<String, BTreeSet<String>>,
    retired_artifact_paths: BTreeSet<String>,
    cleanup_task: Option<JoinHandle<()>>,
}

/// Serializes dynamic-library mutation while allowing a newer request to
/// supersede a compiler process that is already running.
///
/// Compilation happens outside the coordinator lock so another call can publish
/// its token immediately. Only the newest token for a script is allowed to load
/// and register an artifact; an older result is discarded without touching the
/// last known-good runtime generation.
#[derive(Clone)]
pub struct DynamicScriptBuildCoordinator {
    inner: Arc<Mutex<CoordinatorInner>>,
    loader: Arc<dyn DynamicScriptLibraryLoading>,
    script_runtime: ScriptRuntime,
}

impl DynamicScriptBuildCoordinator {
    pub fn new(
        compiler: DynamicScriptCompilerHandle,
        loader: Arc<dyn DynamicScriptLibraryLoading>,
        script_runtime: ScriptRuntime,
    ) -> Self {
        Self {
            inner: Arc::new(Mutex::new(CoordinatorInner {
                compiler,
                is_changing_compiler: false,
                next_request_id: 0,
                newest_request_by_script_id: BTreeMap::new(),
                active_compilations: BTreeMap::new(),
                explicitly_cancelled_request_ids: BTreeSet::new(),
                loaded_artifact_paths: BTreeMap::new(),
                registered_identifiers: BTreeMap::new(),
                retired_artifact_paths: BTreeSet::new(),
                cleanup_task: None,
            })),
            loader,
            script_runtime,
        }
    }

    pub fn begin_compiler_change(
        &self,
        compiler: DynamicScriptCompilerHandle,
    ) -> Result<DynamicScriptCompilerHandle, SwiftToolchainError> {
        let mut inner = lock(&self.inner);
        if inner.is_changing_compiler || !inner.active_compilations.is_empty() {
            return Err(SwiftToolchainError::Unavailable(
                "Wait for script compilation to finish before changing the Rust toolchain."
                    .to_string(),
            ));
        }
        let previous = inner.compiler.clone();
        inner.is_changing_compiler = true;
        inner.compiler = compiler;
        Ok(previous)
    }

    pub fn finish_compiler_change(&self, restoring: Option<DynamicScriptCompilerHandle>) {
        let mut inner = lock(&self.inner);
        if let Some(compiler) = restoring {
            inner.compiler = compiler;
        }
        inner.is_changing_compiler = false;
    }

    pub fn build(
        &self,
        script_id: &str,
        legacy_identifiers: &[String],
        source_url: &Path,
    ) -> DynamicScriptBuildOutcome {
        let (request_id, cancellation, compiler) = {
            let mut inner = lock(&self.inner);
            if inner.is_changing_compiler {
                return DynamicScriptBuildOutcome::Failed {
                    message:
                        "The Rust toolchain is being changed. Retry script compilation when the change finishes."
                            .to_string(),
                };
            }
            if let Some(active) = inner.active_compilations.get(script_id) {
                active.cancellation.cancel();
            }
            inner.next_request_id = inner.next_request_id.wrapping_add(1);
            let request_id = inner.next_request_id;
            inner
                .newest_request_by_script_id
                .insert(script_id.to_string(), request_id);
            let cancellation = ScriptCompilationCancellationToken::new();
            inner.active_compilations.insert(
                script_id.to_string(),
                ActiveCompilation {
                    request_id,
                    cancellation: cancellation.clone(),
                },
            );
            (request_id, cancellation, inner.compiler.clone())
        };
        let _registration = ActiveCompilationRegistration {
            inner: self.inner.clone(),
            script_id: script_id.to_string(),
            request_id,
        };
        let source_path = source_url.to_string_lossy().into_owned();

        // Swift ran this on a detached task; here the compiler is synchronous and
        // the coordinator lock is already released, so `cancel` and a newer
        // `build` proceed concurrently.
        let compilation = compiler.compile(&source_path, script_id, &cancellation);

        let was_explicitly_cancelled = lock(&self.inner)
            .explicitly_cancelled_request_ids
            .contains(&request_id);

        if lock(&self.inner)
            .newest_request_by_script_id
            .get(script_id)
            .copied()
            != Some(request_id)
        {
            if let Ok(artifact) = &compilation {
                remove_file(&artifact.output_path);
            }
            return DynamicScriptBuildOutcome::Superseded;
        }
        if was_explicitly_cancelled {
            if let Ok(artifact) = &compilation {
                remove_file(&artifact.output_path);
            }
            return DynamicScriptBuildOutcome::Cancelled;
        }

        match compilation {
            Err(error) => {
                if was_explicitly_cancelled || error == ScriptCompileError::Cancelled {
                    return DynamicScriptBuildOutcome::Cancelled;
                }
                DynamicScriptBuildOutcome::Failed {
                    message: error.to_string(),
                }
            }
            Ok(artifact) => {
                let factory = match self.loader.load_factory(script_id, &artifact.output_path) {
                    Ok(factory) => factory,
                    Err(error) => {
                        remove_file(&artifact.output_path);
                        return DynamicScriptBuildOutcome::Failed {
                            message: error.to_string(),
                        };
                    }
                };
                if lock(&self.inner)
                    .newest_request_by_script_id
                    .get(script_id)
                    .copied()
                    != Some(request_id)
                {
                    self.loader.unload(script_id);
                    self.retire_artifact(&artifact.output_path);
                    return DynamicScriptBuildOutcome::Superseded;
                }

                let definition = self.loader.definition(script_id);
                let mut next_identifiers: BTreeSet<String> = BTreeSet::new();
                next_identifiers.insert(script_id.to_string());
                next_identifiers.extend(legacy_identifiers.iter().cloned());
                let previous_identifiers = lock(&self.inner)
                    .registered_identifiers
                    .get(script_id)
                    .cloned()
                    .unwrap_or_default();
                // Cancellation can arrive after cargo exits while the caller is
                // about to register; Swift checked this inside `MainActor.run`.
                let did_register = if cancellation.is_cancelled() {
                    false
                } else {
                    for identifier in previous_identifiers.difference(&next_identifiers) {
                        self.script_runtime.unregister_named(identifier);
                    }
                    for identifier in &next_identifiers {
                        register_factory(&self.script_runtime, identifier, &definition, &factory);
                    }
                    true
                };
                if !did_register {
                    let is_newest = lock(&self.inner)
                        .newest_request_by_script_id
                        .get(script_id)
                        .copied()
                        == Some(request_id);
                    if is_newest {
                        self.loader.unload(script_id);
                    }
                    self.retire_artifact(&artifact.output_path);
                    return if is_newest {
                        DynamicScriptBuildOutcome::Cancelled
                    } else {
                        DynamicScriptBuildOutcome::Superseded
                    };
                }
                lock(&self.inner)
                    .registered_identifiers
                    .insert(script_id.to_string(), next_identifiers);
                let previous_path = lock(&self.inner)
                    .loaded_artifact_paths
                    .insert(script_id.to_string(), artifact.output_path.clone());
                if let Some(previous) = previous_path
                    && previous != artifact.output_path
                {
                    self.retire_artifact(&previous);
                }
                self.cleanup_retired_artifacts();
                // Registration is a suspension point in Swift. A newer request
                // may have arrived while it was being scheduled; keep this valid
                // generation as the last-known-good fallback, but never let its
                // completion overwrite the newer build state.
                if lock(&self.inner)
                    .newest_request_by_script_id
                    .get(script_id)
                    .copied()
                    != Some(request_id)
                {
                    return DynamicScriptBuildOutcome::Superseded;
                }
                DynamicScriptBuildOutcome::Succeeded {
                    stdout: artifact.stdout,
                    stderr: artifact.stderr,
                }
            }
        }
    }

    pub fn cancel(&self, script_id: &str) {
        let mut inner = lock(&self.inner);
        let Some(request_id) = inner
            .active_compilations
            .get(script_id)
            .map(|active| active.request_id)
        else {
            return;
        };
        inner.explicitly_cancelled_request_ids.insert(request_id);
        if let Some(active) = inner.active_compilations.get(script_id) {
            active.cancellation.cancel();
        }
    }

    pub fn unload(&self, script_id: &str) {
        let identifiers = {
            let mut inner = lock(&self.inner);
            if let Some(active) = inner.active_compilations.get(script_id) {
                active.cancellation.cancel();
            }
            inner.active_compilations.remove(script_id);
            inner.next_request_id = inner.next_request_id.wrapping_add(1);
            let request_id = inner.next_request_id;
            inner
                .newest_request_by_script_id
                .insert(script_id.to_string(), request_id);
            inner
                .registered_identifiers
                .remove(script_id)
                .unwrap_or_else(|| {
                    let mut identifiers = BTreeSet::new();
                    identifiers.insert(script_id.to_string());
                    identifiers
                })
        };
        for identifier in &identifiers {
            self.script_runtime.unregister_named(identifier);
        }
        self.loader.unload(script_id);
        let path = lock(&self.inner).loaded_artifact_paths.remove(script_id);
        if let Some(path) = path {
            self.retire_artifact(&path);
        }
        self.cleanup_retired_artifacts();
    }

    fn retire_artifact(&self, path: &str) {
        lock(&self.inner)
            .retired_artifact_paths
            .insert(path.to_string());
        schedule_retired_artifact_cleanup(&self.inner);
    }

    /// On Windows an old DLL cannot be deleted until the runtime releases the
    /// final callback that retains it. Retry briefly after subsequent frames and
    /// keep any remaining path recorded for the next build/unload operation.
    fn cleanup_retired_artifacts(&self) {
        cleanup_retired_artifacts(&self.inner);
    }
}

/// Removes a script's registration from its previous identifiers when the
/// runtime's factory slot is infallible.
fn register_factory(
    runtime: &ScriptRuntime,
    identifier: &str,
    definition: &ScriptDefinition,
    factory: &ScriptFactory,
) {
    let factory = factory.clone();
    runtime.register_factory(Some(identifier), "{}", definition.clone(), move || {
        // `register_factory` takes infallible factories. Swift's runtime kept
        // the throwing factory and surfaced the error at instantiation; the
        // Rust runtime has no fallible slot, so a failure is reported and the
        // binding stays inert.
        factory().unwrap_or_else(|error| {
            LogSystem::logger("com.cove.editor.scripting").log(&LogEvent::new(
                Level::Error,
                format!("dynamic script factory failed: {error}"),
            ));
            Script::new(None, None, None, None)
        })
    });
}

struct ActiveCompilationRegistration {
    inner: Arc<Mutex<CoordinatorInner>>,
    script_id: String,
    request_id: u64,
}

impl Drop for ActiveCompilationRegistration {
    fn drop(&mut self) {
        let mut inner = lock(&self.inner);
        if inner
            .active_compilations
            .get(&self.script_id)
            .map(|active| active.request_id)
            == Some(self.request_id)
        {
            inner.active_compilations.remove(&self.script_id);
        }
        inner
            .explicitly_cancelled_request_ids
            .remove(&self.request_id);
    }
}

fn schedule_retired_artifact_cleanup(inner: &Arc<Mutex<CoordinatorInner>>) {
    let weak: Weak<Mutex<CoordinatorInner>> = Arc::downgrade(inner);
    {
        let mut guard = lock(inner);
        if guard.cleanup_task.is_some() {
            return;
        }
        guard.cleanup_task = Some(thread::spawn(move || {
            for _ in 0..12 {
                thread::sleep(Duration::from_millis(250));
                let Some(inner) = weak.upgrade() else {
                    return;
                };
                cleanup_retired_artifacts(&inner);
                if lock(&inner).retired_artifact_paths.is_empty() {
                    break;
                }
            }
            if let Some(inner) = weak.upgrade() {
                lock(&inner).cleanup_task = None;
            }
        }));
    }
}

fn cleanup_retired_artifacts(inner: &Arc<Mutex<CoordinatorInner>>) {
    let paths: Vec<String> = {
        let guard = lock(inner);
        guard.retired_artifact_paths.iter().cloned().collect()
    };
    let mut removed_paths: Vec<String> = Vec::new();
    for path in paths {
        if Path::new(&path).exists() && std::fs::remove_file(&path).is_err() {
            // The mapped image is still leased by an active script. Keep it in
            // the retirement set and retry after the runtime advances.
            continue;
        }
        removed_paths.push(path);
    }
    let mut guard = lock(inner);
    for path in removed_paths {
        guard.retired_artifact_paths.remove(&path);
    }
}

fn remove_file(path: &str) {
    let _ = std::fs::remove_file(path);
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

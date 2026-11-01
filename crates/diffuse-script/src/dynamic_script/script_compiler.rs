//! D1: build a project's Scripts cdylib and publish an independently loadable generation.

use cove_system::{
    atomic_file::AtomicFile, command::ProcessCommand, files::Access, native_process::NativeProcess,
};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs,
    io::{self, Read},
    path::{Path, PathBuf},
    sync::{Arc, Condvar, Mutex, MutexGuard},
    thread,
    time::{Duration, Instant},
};

type ExitStatus = Arc<(Mutex<Option<i32>>, Condvar)>;

struct CompilationProcess {
    native: NativeProcess,
    exit: ExitStatus,
}

impl CompilationProcess {
    fn stop(self: &Arc<Self>) {
        if lock(&self.exit.0).is_some() {
            return;
        }
        #[cfg(windows)]
        self.native.terminate(true);
        #[cfg(not(windows))]
        self.native.terminate(false);
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        {
            let process = self.clone();
            let fallback = self.clone();
            if thread::Builder::new()
                .name("diffuse.script.cancel".into())
                .spawn(move || {
                    thread::sleep(Duration::from_millis(250));
                    // NativeProcess::is_running is cleared by terminate(false), so use actual exit notification.
                    if lock(&process.exit.0).is_none() {
                        process.native.terminate(true);
                    }
                })
                .is_err()
            {
                fallback.native.terminate(true);
            }
        }
    }
}

#[derive(Default)]
struct CancellationState {
    process: Option<Arc<CompilationProcess>>,
    cancelled: bool,
}

/// Clones refer to the same cancellation flag and currently registered cargo process.
#[derive(Clone, Default)]
pub struct ScriptCompilationCancellationToken {
    state: Arc<Mutex<CancellationState>>,
}

impl ScriptCompilationCancellationToken {
    pub fn new() -> Self {
        Self::default()
    }
    pub fn is_cancelled(&self) -> bool {
        lock(&self.state).cancelled
    }
    pub fn cancel(&self) {
        let process = {
            let mut state = lock(&self.state);
            state.cancelled = true;
            state.process.clone()
        };
        if let Some(process) = process {
            process.stop();
        }
    }
    fn register(&self, process: Arc<CompilationProcess>) -> bool {
        let mut state = lock(&self.state);
        if state.cancelled {
            return false;
        }
        state.process = Some(process);
        true
    }
    fn unregister(&self, process: &Arc<CompilationProcess>) {
        let mut state = lock(&self.state);
        if state
            .process
            .as_ref()
            .is_some_and(|current| Arc::ptr_eq(current, process))
        {
            state.process = None;
        }
    }
}

struct Registration<'a> {
    token: Option<&'a ScriptCompilationCancellationToken>,
    process: Arc<CompilationProcess>,
}
impl Drop for Registration<'_> {
    fn drop(&mut self) {
        if let Some(token) = self.token {
            token.unregister(&self.process);
        }
    }
}

#[derive(Clone, Debug)]
pub struct ScriptCompiler {
    pub cargo_path: String,
    /// Project cache directory. Cargo's reusable cache lives in its cargo-target child.
    pub output_directory: PathBuf,
    pub environment: BTreeMap<String, String>,
    pub library_target: Option<String>,
    pub target_triple: Option<String>,
    /// None preserves the source compiler's unbounded compilation; callers may supply a deadline.
    pub timeout: Option<Duration>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ScriptCompilerDiagnostic {
    pub level: String,
    pub message: String,
    pub rendered: Option<String>,
    /// Complete rustc message, including code, children, spans and suggested replacements.
    pub details: serde_json::Value,
}

#[derive(Clone, Debug, PartialEq)]
pub struct CompilationResult {
    pub output_path: String,
    pub stdout: String,
    pub stderr: String,
    pub diagnostics: Vec<ScriptCompilerDiagnostic>,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ScriptCompileError {
    #[error("Rust script compilation was cancelled.")]
    Cancelled,
    #[error("Rust script compilation exceeded its deadline.\n{stderr}\n{stdout}")]
    TimedOut { stderr: String, stdout: String },
    #[error("Rust compilation failed with exit code {exit_code}:\n{stderr}\n{stdout}")]
    CompilationFailed {
        exit_code: i32,
        stderr: String,
        stdout: String,
    },
    #[error("Could not find executable '{0}' on PATH.")]
    ExecutableNotFound(String),
    #[error("Could not find a Scripts Cargo.toml for '{0}'.")]
    ManifestNotFound(String),
    #[error("Invalid script identifier '{0}'.")]
    InvalidScriptID(String),
    #[error("The script compilation timeout exceeds the platform clock range.")]
    InvalidTimeout,
    #[error("Cargo did not report a cdylib artifact for '{0}'.")]
    ArtifactNotFound(String),
    #[error("Cargo reported multiple cdylib artifacts; select a library target: {0:?}")]
    AmbiguousArtifacts(Vec<String>),
    #[error("{operation}: {diagnostic}")]
    Io {
        operation: String,
        diagnostic: String,
    },
}

fn io_error(operation: impl Into<String>, error: impl std::fmt::Display) -> ScriptCompileError {
    ScriptCompileError::Io {
        operation: operation.into(),
        diagnostic: error.to_string(),
    }
}
fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|error| error.into_inner())
}

impl ScriptCompiler {
    pub fn new(output_directory: impl Into<PathBuf>) -> Self {
        Self {
            cargo_path: "cargo".into(),
            output_directory: output_directory.into(),
            environment: std::env::vars().collect(),
            library_target: None,
            target_triple: None,
            timeout: None,
        }
    }

    /// Accepts a Scripts crate directory, its Cargo.toml, or a source file within it.
    pub fn compile(
        &self,
        source_path: impl AsRef<Path>,
        script_id: &str,
        cancellation: Option<&ScriptCompilationCancellationToken>,
    ) -> Result<CompilationResult, ScriptCompileError> {
        check_cancelled(cancellation)?;
        if script_id.is_empty()
            || script_id == "."
            || script_id == ".."
            || script_id.contains(['/', '\\', '\0'])
        {
            return Err(ScriptCompileError::InvalidScriptID(script_id.into()));
        }
        let manifest = Self::manifest_path(source_path.as_ref())?;
        let directory = manifest
            .parent()
            .ok_or_else(|| ScriptCompileError::ManifestNotFound(manifest.display().to_string()))?
            .to_path_buf();
        fs::create_dir_all(&self.output_directory)
            .map_err(|error| io_error("create script output directory", error))?;
        let output_directory = fs::canonicalize(&self.output_directory)
            .map_err(|error| io_error("resolve script output directory", error))?;
        let target_directory = output_directory.join("cargo-target");
        let executable = Self::resolve_executable_url(&self.cargo_path, &self.environment)?;
        let mut command = ProcessCommand::new(executable, directory);
        command.arguments = self.build_arguments(&manifest);
        command.environment = cove_system::tool_locator::ProcessEnvironment::setting(
            &target_directory.to_string_lossy(),
            "CARGO_TARGET_DIR",
            &self.environment,
        );
        command.environment = cove_system::tool_locator::ProcessEnvironment::setting(
            "unwind",
            "CARGO_PROFILE_RELEASE_PANIC",
            &command.environment,
        );
        command.environment = cove_system::tool_locator::ProcessEnvironment::setting(
            "true",
            "CARGO_PROFILE_RELEASE_OVERFLOW_CHECKS",
            &command.environment,
        );
        let output = self.run(&command, cancellation)?;
        check_cancelled(cancellation)?;
        if output.timed_out {
            return Err(ScriptCompileError::TimedOut {
                stderr: output.stderr,
                stdout: output.stdout,
            });
        }
        let messages =
            CargoMessages::parse(&output.stdout, &manifest, self.library_target.as_deref());
        // Rendered diagnostics remain available even though cargo writes compiler-message records to stdout.
        let stderr = combined_diagnostics(&output.stderr, &messages.diagnostics);
        if output.status != 0 || messages.build_succeeded == Some(false) {
            return Err(ScriptCompileError::CompilationFailed {
                exit_code: output.status,
                stderr,
                stdout: output.stdout,
            });
        }
        let artifact = match messages.artifacts.as_slice() {
            [] => {
                return Err(ScriptCompileError::ArtifactNotFound(
                    manifest.display().to_string(),
                ));
            }
            [artifact] => artifact,
            artifacts => {
                return Err(ScriptCompileError::AmbiguousArtifacts(
                    artifacts
                        .iter()
                        .map(|path| path.display().to_string())
                        .collect(),
                ));
            }
        };
        let extension = artifact
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or(Self::dylib_extension());
        let output_path = output_directory.join(format!(
            "{script_id}-{}.{extension}",
            diffuse_kernel::codable::new_uuid()
        ));
        let publish = (|| {
            let bytes = fs::read(artifact)
                .map_err(|error| io_error("read cargo cdylib artifact", error))?;
            check_cancelled(cancellation)?;
            AtomicFile::write(&bytes, &output_path, Access::Inherit)
                .map_err(|error| io_error("publish script generation", error))?;
            check_cancelled(cancellation)?;
            Ok(CompilationResult {
                output_path: output_path.to_string_lossy().into_owned(),
                stdout: output.stdout,
                stderr,
                diagnostics: messages.diagnostics,
            })
        })();
        if publish.is_err() {
            let _ = fs::remove_file(&output_path);
        }
        publish
    }

    pub fn build_arguments(&self, manifest: &Path) -> Vec<String> {
        let mut args = vec![
            "build".into(),
            "--release".into(),
            "--message-format=json".into(),
            "--lib".into(),
            "--manifest-path".into(),
            manifest.to_string_lossy().into_owned(),
        ];
        if let Some(target) = &self.target_triple {
            args.extend(["--target".into(), target.clone()]);
        }
        args
    }

    pub fn manifest_path(source: &Path) -> Result<PathBuf, ScriptCompileError> {
        let source =
            fs::canonicalize(source).map_err(|error| io_error("resolve script source", error))?;
        let found = if source.is_dir() {
            let scripts = source.join("Scripts/Cargo.toml");
            let manifest = source.join("Cargo.toml");
            if scripts.is_file() {
                Some(scripts)
            } else {
                manifest.is_file().then_some(manifest)
            }
        } else if source.file_name().is_some_and(|name| name == "Cargo.toml") {
            Some(source.clone())
        } else {
            source
                .parent()
                .into_iter()
                .flat_map(Path::ancestors)
                .map(|directory| directory.join("Cargo.toml"))
                .find(|manifest| manifest.is_file())
        };
        found.ok_or_else(|| ScriptCompileError::ManifestNotFound(source.display().to_string()))
    }

    /// Exact candidates are checked before PATH traversal, including Windows PATHEXT and empty PATH entries.
    pub fn resolve_executable_url(
        executable: &str,
        environment: &BTreeMap<String, String>,
    ) -> Result<PathBuf, ScriptCompileError> {
        let cwd = std::env::current_dir()
            .map_err(|error| io_error("resolve compiler working directory", error))?;
        let is_executable = |path: &Path| {
            let Ok(metadata) = fs::metadata(path) else {
                return false;
            };
            if !metadata.is_file() {
                return false;
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                metadata.permissions().mode() & 0o111 != 0
            }
            #[cfg(not(unix))]
            {
                true
            }
        };
        if executable.contains(['/', '\\']) {
            let path = cwd.join(executable);
            return if is_executable(&path) {
                Ok(path)
            } else {
                Err(ScriptCompileError::ExecutableNotFound(executable.into()))
            };
        }
        let path = cove_system::tool_locator::ProcessEnvironment::value("PATH", environment)
            .unwrap_or_default();
        #[cfg(windows)]
        let (separator, candidates) = {
            let mut candidates = vec![executable.to_owned()];
            if Path::new(executable).extension().is_none() {
                candidates.extend(
                    cove_system::tool_locator::ProcessEnvironment::value("PATHEXT", environment)
                        .unwrap_or_else(|| ".EXE;.CMD;.BAT".into())
                        .split(';')
                        .filter(|suffix| !suffix.is_empty())
                        .map(|suffix| format!("{executable}{suffix}")),
                );
            }
            (';', candidates)
        };
        #[cfg(not(windows))]
        let (separator, candidates) = (':', vec![executable.to_owned()]);
        for directory in path.split(separator) {
            for candidate in &candidates {
                let path = cwd
                    .join(if directory.is_empty() { "." } else { directory })
                    .join(candidate);
                if is_executable(&path) {
                    return Ok(path);
                }
            }
        }
        Err(ScriptCompileError::ExecutableNotFound(executable.into()))
    }

    pub const fn dylib_extension() -> &'static str {
        if cfg!(any(target_os = "macos", target_os = "ios")) {
            "dylib"
        } else if cfg!(windows) {
            "dll"
        } else {
            "so"
        }
    }

    fn run(
        &self,
        command: &ProcessCommand,
        cancellation: Option<&ScriptCompilationCancellationToken>,
    ) -> Result<CompilerOutput, ScriptCompileError> {
        check_cancelled(cancellation)?;
        let deadline = self
            .timeout
            .map(|timeout| {
                Instant::now()
                    .checked_add(timeout)
                    .ok_or(ScriptCompileError::InvalidTimeout)
            })
            .transpose()?;
        let process = Arc::new(CompilationProcess {
            native: NativeProcess::new(),
            exit: Arc::new((Mutex::new(None), Condvar::new())),
        });
        let exit = process.exit.clone();
        let pipes = process
            .native
            .start(
                command,
                Arc::new(move |status| {
                    *lock(&exit.0) = Some(status);
                    exit.1.notify_all();
                }),
            )
            .map_err(|error| io_error("start cargo", error))?;
        drop(pipes.input);
        let _registration = Registration {
            token: cancellation,
            process: process.clone(),
        };
        if cancellation.is_some_and(|token| !token.register(process.clone())) {
            process.stop();
        }
        thread::scope(|scope| {
            // On a reader-thread launch failure kill before scope joins any already-running reader.
            struct StopOnDrop(Arc<CompilationProcess>);
            impl Drop for StopOnDrop {
                fn drop(&mut self) {
                    if lock(&self.0.exit.0).is_none() {
                        self.0.native.terminate(true);
                    }
                }
            }
            let _stop = StopOnDrop(process.clone());
            let stdout = thread::Builder::new()
                .name("diffuse.script.stdout".into())
                .spawn_scoped(scope, move || read_output(pipes.output))
                .map_err(|error| io_error("start cargo stdout reader", error))?;
            let stderr = thread::Builder::new()
                .name("diffuse.script.stderr".into())
                .spawn_scoped(scope, move || read_output(pipes.errors))
                .map_err(|error| io_error("start cargo stderr reader", error))?;
            let mut timed_out = false;
            let status = {
                let mut status = lock(&process.exit.0);
                loop {
                    if let Some(status) = *status {
                        break status;
                    }
                    if let Some(deadline) = deadline
                        && !timed_out
                    {
                        let now = Instant::now();
                        if now >= deadline {
                            timed_out = true;
                            drop(status);
                            process.stop();
                            status = lock(&process.exit.0);
                            continue;
                        }
                        status = process
                            .exit
                            .1
                            .wait_timeout(status, deadline - now)
                            .unwrap_or_else(|error| error.into_inner())
                            .0;
                    } else {
                        status = process
                            .exit
                            .1
                            .wait(status)
                            .unwrap_or_else(|error| error.into_inner());
                    }
                }
            };
            let stdout = stdout
                .join()
                .map_err(|_| io_error("read cargo stdout", "reader panicked"))?
                .map_err(|error| io_error("read cargo stdout", error))?;
            let stderr = stderr
                .join()
                .map_err(|_| io_error("read cargo stderr", "reader panicked"))?
                .map_err(|error| io_error("read cargo stderr", error))?;
            Ok(CompilerOutput {
                status,
                stdout: String::from_utf8(stdout).unwrap_or_default(),
                stderr: String::from_utf8(stderr).unwrap_or_default(),
                timed_out,
            })
        })
    }
}

fn check_cancelled(
    token: Option<&ScriptCompilationCancellationToken>,
) -> Result<(), ScriptCompileError> {
    if token.is_some_and(ScriptCompilationCancellationToken::is_cancelled) {
        Err(ScriptCompileError::Cancelled)
    } else {
        Ok(())
    }
}
fn read_output(mut reader: impl Read) -> io::Result<Vec<u8>> {
    let mut output = Vec::new();
    reader.read_to_end(&mut output)?;
    Ok(output)
}
struct CompilerOutput {
    status: i32,
    stdout: String,
    stderr: String,
    timed_out: bool,
}

#[derive(Default)]
struct CargoMessages {
    artifacts: Vec<PathBuf>,
    diagnostics: Vec<ScriptCompilerDiagnostic>,
    build_succeeded: Option<bool>,
}
impl CargoMessages {
    fn parse(stdout: &str, manifest: &Path, library_target: Option<&str>) -> Self {
        let mut result = Self::default();
        for line in stdout.lines() {
            let Ok(value) = serde_json::from_str::<serde_json::Value>(line) else {
                continue;
            };
            match value.get("reason").and_then(serde_json::Value::as_str) {
                Some("compiler-message") => {
                    if let Some(message) = value.get("message") {
                        result.diagnostics.push(ScriptCompilerDiagnostic {
                            level: message
                                .get("level")
                                .and_then(serde_json::Value::as_str)
                                .unwrap_or("")
                                .into(),
                            message: message
                                .get("message")
                                .and_then(serde_json::Value::as_str)
                                .unwrap_or("")
                                .into(),
                            rendered: message
                                .get("rendered")
                                .and_then(serde_json::Value::as_str)
                                .map(str::to_owned),
                            details: message.clone(),
                        });
                    }
                }
                Some("build-finished") => {
                    result.build_succeeded =
                        value.get("success").and_then(serde_json::Value::as_bool)
                }
                Some("compiler-artifact") => {
                    if let Some(reported) = value
                        .get("manifest_path")
                        .and_then(serde_json::Value::as_str)
                    {
                        let reported =
                            fs::canonicalize(reported).unwrap_or_else(|_| PathBuf::from(reported));
                        if reported != manifest {
                            continue;
                        }
                    }
                    let Some(target) = value.get("target") else {
                        continue;
                    };
                    if library_target.is_some_and(|name| {
                        target.get("name").and_then(serde_json::Value::as_str) != Some(name)
                    }) {
                        continue;
                    }
                    if !target
                        .get("crate_types")
                        .and_then(serde_json::Value::as_array)
                        .is_some_and(|types| {
                            types.iter().any(|kind| kind.as_str() == Some("cdylib"))
                        })
                    {
                        continue;
                    }
                    for filename in value
                        .get("filenames")
                        .and_then(serde_json::Value::as_array)
                        .into_iter()
                        .flatten()
                        .filter_map(serde_json::Value::as_str)
                    {
                        let path = PathBuf::from(filename);
                        if path
                            .extension()
                            .and_then(|value| value.to_str())
                            .is_some_and(|extension| matches!(extension, "dylib" | "so" | "dll"))
                            && !result.artifacts.contains(&path)
                        {
                            result.artifacts.push(path);
                        }
                    }
                }
                _ => {}
            }
        }
        result
    }
}
fn combined_diagnostics(stderr: &str, diagnostics: &[ScriptCompilerDiagnostic]) -> String {
    let rendered: Vec<_> = diagnostics
        .iter()
        .filter_map(|diagnostic| diagnostic.rendered.as_deref())
        .collect();
    if rendered.is_empty() {
        stderr.into()
    } else if stderr.is_empty() {
        rendered.join("")
    } else {
        format!("{stderr}\n{}", rendered.join(""))
    }
}

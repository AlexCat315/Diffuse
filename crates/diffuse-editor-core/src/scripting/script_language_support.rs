//! Translation of `Editor/Sources/EditorCore/Scripting/ScriptLanguageSupport.swift`
//! (MIGRATION.md §4 d1: the server is `rust-analyzer`, user scripts are cargo
//! crates).
//!
//! Orchestrates one language-server session for the project's script files.
//!
//! This type owns *document lifecycle*: it mirrors script sources into the
//! shadow analysis workspace (`ScriptLanguageWorkspace`), keeps versions in step
//! with the editor, publishes diagnostics, and forwards semantic queries. Wire
//! format and process management live one layer down ([`LspClient`]).
//!
//! Diagnostics are asynchronous and unsolicited, so they arrive through a
//! handler registered at startup rather than awaiting each edit.
//!
//! Swift made this an `actor`. MIGRATION.md §5.5 maps it to a struct whose state
//! sits behind one mutex, with `Task` becoming a thread plus an `AtomicBool`
//! cancellation token. User handlers are always invoked after the lock is
//! released, so a callback may re-enter the service the way an `await` inside
//! the actor could.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, Weak};
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cove_logging::{Level, LogEvent, LogSystem};
use cove_system::command::ProcessCommand;
use cove_ui_compose::primitives::text::text_buffer::TextBuffer;
use diffuse_lsp::byte_stream::LspNotification;
use diffuse_lsp::configuration::{ConnectHook, LanguageServerConfiguration, file_uri};
use diffuse_lsp::lsp::client::LspClient;
use diffuse_lsp::lsp::error::{LspClientError, LspFailure};
use diffuse_lsp::lsp::transport::LanguageServerTransport;
use diffuse_plugin::Uuid;
use serde_json::{Map, Value, json};

use crate::contributions::languages::LanguageCatalog;
use crate::scripting::dynamic::dynamic_script_manager::{ScriptFile, ScriptLanguageSource};
use crate::scripting::rust_analyzer::language::assistance::ScriptWorkspaceSymbol;
use crate::scripting::rust_analyzer::language::details::{
    ScriptAnalysisHealth, ScriptIndexProgress, ScriptLanguageLogLevel,
    ScriptLanguageSemanticEvidence, ScriptLanguageServiceDetails,
};
use crate::scripting::rust_analyzer::language::editing::{
    ScriptLanguageEditError, ScriptSemanticContext, ScriptSemanticDocument, ScriptSemanticResponse,
};
use crate::scripting::rust_analyzer::language::script_language_lifecycle::{
    ScriptLanguageLifecycle, ScriptLanguageServiceUpdate, StateHandler,
};
use crate::scripting::rust_analyzer::language::script_language_models::{
    ScriptCompletionItem, ScriptCompletionResult, ScriptDefinitionLocation, ScriptHoverResult,
    ScriptLanguageDiagnostic, ScriptLanguageDiagnosticUpdate, ScriptLanguageServiceState,
    ScriptLanguageSupportError,
};
use crate::scripting::rust_analyzer::language::script_language_position::ScriptLanguagePosition;
use crate::scripting::rust_analyzer::language::script_language_protocol::{
    CompletionTrigger, ScriptLanguageQueries, ScriptLanguageReplies,
};
use crate::scripting::rust_analyzer::language::script_language_workspace::{
    ScriptLanguageDocument, ScriptLanguageWorkspace,
};
use crate::scripting::rust_analyzer::language::watched_files::{
    ScriptWatchedFileChange, ScriptWatchedFiles,
};
use crate::scripting::rust_analyzer::server::capabilities::{
    RustAnalyzerCapabilities, RustAnalyzerCommandLine,
};
use crate::scripting::rust_analyzer::server::executable_locator::RustAnalyzerExecutableLocator;

pub type DiagnosticsHandler = Arc<dyn Fn(ScriptLanguageDiagnosticUpdate) + Send + Sync>;
pub type DetailsHandler = Arc<dyn Fn(ScriptLanguageServiceDetails) + Send + Sync>;

/// Swift's `connect` closure: hosts with their own transport (plugins, tests)
/// replace process spawning.
pub type ConnectTransport =
    Arc<dyn Fn(&ProcessCommand) -> Result<LanguageServerTransport, String> + Send + Sync>;

/// Swift's `memoryUsage` closure: the plugin hosting the server reports its
/// resident bytes.
pub type MemoryUsage = Arc<dyn Fn() -> Option<u64> + Send + Sync>;

/// Grace period before an unsolicited edit is pushed to the server. Typing
/// produces dozens of changes per second; only settled text is worth
/// re-indexing.
const CHANGE_DEBOUNCE: Duration = Duration::from_millis(180);
/// Interactive queries must never wedge the editor: a slow index build is
/// reported as "no result" instead of blocking the popup.
const QUERY_TIMEOUT: Duration = Duration::from_secs(6);

/// How long a session must have been healthy before a failure stops counting
/// against the retry budget.
const RECOVERY_WINDOW: Duration = Duration::from_secs(30);

/// Generated reference documents past this size are refused instead of opening
/// a multi-megabyte buffer.
const MAXIMUM_REFERENCE_DOCUMENT_BYTES: usize = 16_777_216;

/// One failed service operation. Swift threw a mix of `LSPClientError`,
/// `ScriptLanguageEditError`, `ScriptLanguageSupportError`, `CancellationError`
/// and toolchain `Error`s; the Rust port keeps them distinguishable.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum ScriptLanguageSupportFailure {
    #[error("The language service operation was cancelled.")]
    Cancelled,
    #[error(transparent)]
    Client(#[from] LspClientError),
    #[error(transparent)]
    Edit(#[from] ScriptLanguageEditError),
    #[error(transparent)]
    Support(#[from] ScriptLanguageSupportError),
    #[error("{0}")]
    Service(String),
}

impl ScriptLanguageSupportFailure {
    /// Swift's `error.localizedDescription`.
    pub fn error_description(&self) -> String {
        self.to_string()
    }
}

/// One unit of work started by the service. Swift used `Task` and `cancel()`;
/// a join handle cannot be interrupted, so the thread polls this token.
struct CancellableTask {
    cancel: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl CancellableTask {
    fn new(cancel: Arc<AtomicBool>, handle: JoinHandle<()>) -> Self {
        CancellableTask {
            cancel,
            handle: Some(handle),
        }
    }

    fn cancel(&mut self) {
        self.cancel.store(true, Ordering::SeqCst);
        // Dropping the handle detaches a thread that is still sleeping; it
        // observes the token on its next turn.
        self.handle.take();
    }
}

fn cancel_task(task: &mut Option<CancellableTask>) {
    if let Some(mut task) = task.take() {
        task.cancel();
    }
}

struct DocumentSession {
    document: ScriptLanguageDocument,
    current: TextBuffer,
    sent: TextBuffer,
    revision: u64,
    protocol_version: i64,
    change_task: Option<CancellableTask>,
    diagnostics: Vec<Vec<u8>>,
    environment_failure: Option<String>,
}

impl DocumentSession {
    fn new(
        document: ScriptLanguageDocument,
        current: TextBuffer,
        sent: TextBuffer,
        revision: u64,
    ) -> Self {
        DocumentSession {
            document,
            current,
            sent,
            revision,
            protocol_version: 1,
            change_task: None,
            diagnostics: Vec::new(),
            environment_failure: None,
        }
    }
}

/// A state change or detail snapshot raised while the lock was held, delivered
/// once the caller has released it.
enum Delivery {
    State(StateHandler, ScriptLanguageServiceUpdate),
    Details(DetailsHandler, ScriptLanguageServiceDetails),
    Diagnostics(DiagnosticsHandler, ScriptLanguageDiagnosticUpdate),
}

struct SupportState {
    client: Option<Arc<LspClient>>,
    sessions: BTreeMap<String, DocumentSession>,
    diagnostics_handler: Option<DiagnosticsHandler>,
    lifecycle: ScriptLanguageLifecycle,
    state_revision: u64,
    details: ScriptLanguageServiceDetails,
    details_handler: Option<DetailsHandler>,
    environment_failure: Option<String>,
    recovery_task: Option<CancellableTask>,
    metrics_task: Option<CancellableTask>,
    watch_task: Option<CancellableTask>,
}

impl SupportState {
    fn new(executable_path: String) -> Self {
        SupportState {
            client: None,
            sessions: BTreeMap::new(),
            diagnostics_handler: None,
            lifecycle: ScriptLanguageLifecycle::new(),
            state_revision: 0,
            details: ScriptLanguageServiceDetails::new(executable_path),
            details_handler: None,
            environment_failure: None,
            recovery_task: None,
            metrics_task: None,
            watch_task: None,
        }
    }
}

/// The private query kinds forwarded by `query`.
enum Query {
    Hover,
    Definition,
    Completion { trigger_character: Option<String> },
}

pub struct ScriptLanguageSupport {
    workspace: ScriptLanguageWorkspace,
    executable_url: PathBuf,
    environment: BTreeMap<String, String>,
    connect_transport: Option<ConnectTransport>,
    memory_usage: Option<MemoryUsage>,
    state: Mutex<SupportState>,
}

impl ScriptLanguageSupport {
    // Swift's designated `init` takes all eight configuration values; they are
    // kept as parameters so no caller can silently drop one.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        scripts_directory_url: PathBuf,
        engine_module_paths: Vec<String>,
        clang_module_map_paths: Vec<String>,
        clang_include_paths: Vec<String>,
        executable_url: PathBuf,
        environment: BTreeMap<String, String>,
        connect: Option<ConnectTransport>,
        memory_usage: Option<MemoryUsage>,
    ) -> Self {
        // Swift derived the SDK and resource directories from `SDKROOT` and
        // `SWIFT_EXEC`; the Rust toolchain reports its sysroot through the
        // `RUSTC` binary (`<sysroot>/bin/rustc`), whose metadata lives in
        // `<sysroot>/lib/rustlib`.
        let sdk_url = environment.get("SDKROOT").map(PathBuf::from);
        let resource_directory_url = environment.get("RUSTC").and_then(|compiler| {
            PathBuf::from(compiler)
                .parent()
                .and_then(|bin| bin.parent())
                .map(|sysroot| sysroot.join("lib").join("rustlib"))
        });
        ScriptLanguageSupport {
            workspace: ScriptLanguageWorkspace::new(
                scripts_directory_url,
                engine_module_paths,
                clang_module_map_paths,
                clang_include_paths,
                sdk_url,
                resource_directory_url,
            ),
            executable_url,
            environment,
            connect_transport: connect,
            memory_usage,
            state: Mutex::new(SupportState::new(String::new())),
        }
    }

    fn lock(&self) -> MutexGuard<'_, SupportState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    // MARK: - Session lifecycle

    pub fn start(
        self: &Arc<Self>,
        sources: &[ScriptLanguageSource],
        on_diagnostics: DiagnosticsHandler,
        on_state_change: Option<StateHandler>,
        on_details_change: Option<DetailsHandler>,
    ) -> Result<(), ScriptLanguageSupportFailure> {
        self.stop();
        let generation = {
            let mut state = self.lock();
            state.lifecycle = ScriptLanguageLifecycle::new();
            state.lifecycle.on_state_change = on_state_change;
            state.diagnostics_handler = Some(on_diagnostics);
            state.details_handler = on_details_change;
            state.details = ScriptLanguageServiceDetails::new(
                self.executable_url.to_string_lossy().into_owned(),
            );
            state.environment_failure = None;
            state.lifecycle.generation.clone()
        };
        self.set_state(ScriptLanguageServiceState::Starting);
        match self.start_session(sources, &generation) {
            Ok(()) => Ok(()),
            Err(error) => {
                if self.lock().lifecycle.generation != generation {
                    return Err(ScriptLanguageSupportFailure::Cancelled);
                }
                // Startup errors are surfaced to the caller. Only an established
                // session reconnects automatically after an unexpected failure.
                cancel_task(&mut self.lock().recovery_task);
                self.set_state(ScriptLanguageServiceState::Unavailable(error.to_string()));
                Err(error)
            }
        }
    }

    /// `synchronize` followed by `connect`; split out so the caller's `do`
    /// block can be translated as a `match`.
    fn start_session(
        self: &Arc<Self>,
        sources: &[ScriptLanguageSource],
        generation: &str,
    ) -> Result<(), ScriptLanguageSupportFailure> {
        let scripts: Vec<(ScriptFile, String)> = sources
            .iter()
            .filter(|source| !source.is_project_source)
            .map(|source| (source.file.clone(), source.text.string_value()))
            .collect();
        let project_sources: Vec<ScriptFile> = sources
            .iter()
            .filter(|source| source.is_project_source)
            .map(|source| source.file.clone())
            .collect();
        let documents = self
            .workspace
            .synchronize(&scripts, &project_sources)
            .map_err(|error| ScriptLanguageSupportFailure::Service(error.to_string()))?;
        let sessions: BTreeMap<String, DocumentSession> = sources
            .iter()
            .filter_map(|source| {
                documents.get(&source.file.identifier).map(|document| {
                    (
                        source.file.identifier.clone(),
                        DocumentSession::new(
                            document.clone(),
                            source.text.clone(),
                            source.text.clone(),
                            source.revision,
                        ),
                    )
                })
            })
            .collect();
        self.lock().sessions = sessions;
        self.connect(generation)
    }

    pub fn restart(
        self: &Arc<Self>,
        sources: &[ScriptLanguageSource],
    ) -> Result<(), ScriptLanguageSupportFailure> {
        let (handler, state_handler, details_handler) = {
            let state = self.lock();
            (
                state
                    .diagnostics_handler
                    .clone()
                    .unwrap_or_else(|| Arc::new(|_| {}) as DiagnosticsHandler),
                state.lifecycle.on_state_change.clone(),
                state.details_handler.clone(),
            )
        };
        self.start(sources, handler, state_handler, details_handler)
    }

    /// Adds a project file to the running session. Scripts change the generated
    /// package and need a restart; a project file is opened where it is.
    pub fn open_project_source(
        &self,
        source: &ScriptLanguageSource,
    ) -> Result<(), ScriptLanguageSupportFailure> {
        let id = source.file.identifier.clone();
        let document = ScriptLanguageWorkspace::project_document(&source.file);
        let ready = {
            let mut state = self.lock();
            if state.sessions.contains_key(&id) {
                return Ok(());
            }
            state.sessions.insert(
                id,
                DocumentSession::new(
                    document.clone(),
                    source.text.clone(),
                    source.text.clone(),
                    source.revision,
                ),
            );
            state.lifecycle.state == ScriptLanguageServiceState::Ready
        };
        if !ready {
            return Ok(());
        }
        self.open(&source.text.string_value(), &document, 1)
    }

    /// The editor wrote the script to disk.
    pub fn did_save(self: &Arc<Self>, script_id: &str) {
        let Some((revision, uri)) = ({
            let state = self.lock();
            state
                .sessions
                .get(script_id)
                .map(|session| (session.revision, file_uri(&session.document.analysis_url)))
        }) else {
            return;
        };
        self.send_change(script_id, revision);
        let client = {
            let state = self.lock();
            if state.lifecycle.state != ScriptLanguageServiceState::Ready {
                None
            } else {
                state.client.clone()
            }
        };
        let Some(client) = client else {
            return;
        };
        let _ = client.notify(
            "textDocument/didSave",
            Some(json!({ "textDocument": { "uri": uri } })),
        );
    }

    fn notify_watched_files(&self, changes: &[ScriptWatchedFileChange], connection_id: &str) {
        let client = {
            let state = self.lock();
            if state.lifecycle.state != ScriptLanguageServiceState::Ready
                || state.lifecycle.connection_id.as_deref() != Some(connection_id)
            {
                None
            } else {
                state.client.clone()
            }
        };
        let Some(client) = client else {
            return;
        };
        let entries: Vec<Value> = changes
            .iter()
            .take(1_000)
            .map(|change| {
                json!({
                    "uri": file_uri(&change.url),
                    "type": change.change_type.raw_value(),
                })
            })
            .collect();
        let _ = client.notify(
            "workspace/didChangeWatchedFiles",
            Some(json!({ "changes": entries })),
        );
    }

    pub fn close_project_source(&self, script_id: &str) {
        let removed = self.lock().sessions.remove(script_id);
        let Some(mut session) = removed else {
            return;
        };
        if let Some(task) = session.change_task.as_mut() {
            task.cancel();
        }
        let client = {
            let state = self.lock();
            if state.lifecycle.state != ScriptLanguageServiceState::Ready {
                None
            } else {
                state.client.clone()
            }
        };
        let Some(client) = client else {
            return;
        };
        let uri = file_uri(&session.document.analysis_url);
        let Ok(params) = ScriptLanguageQueries::did_close(&uri) else {
            return;
        };
        let Ok(params) = serde_json::from_slice::<Value>(&params) else {
            return;
        };
        let _ = client.notify("textDocument/didClose", Some(params));
    }

    pub fn stop(&self) {
        let mut deliveries = Vec::new();
        let (old, was_ready) = {
            let mut state = self.lock();
            cancel_task(&mut state.metrics_task);
            cancel_task(&mut state.watch_task);
            state.details.resident_memory_bytes = None;
            let was_ready = state.lifecycle.state == ScriptLanguageServiceState::Ready;
            state.lifecycle.generation = diffuse_kernel::codable::new_uuid();
            cancel_task(&mut state.recovery_task);
            state.lifecycle.connection_id = None;
            Self::set_state_locked(
                &mut state,
                &mut deliveries,
                ScriptLanguageServiceState::Inactive,
            );
            for session in state.sessions.values_mut() {
                cancel_task(&mut session.change_task);
            }
            let old = state.client.take();
            state.sessions.clear();
            (old, was_ready)
        };
        self.deliver(deliveries);
        if let Some(old) = old {
            if was_ready {
                old.shutdown();
            } else {
                old.stop();
            }
        }
    }

    pub fn is_ready(&self) -> bool {
        self.lock().lifecycle.state == ScriptLanguageServiceState::Ready
    }

    fn connect(self: &Arc<Self>, generation: &str) -> Result<(), ScriptLanguageSupportFailure> {
        {
            let mut state = self.lock();
            if state.lifecycle.generation != generation {
                return Err(ScriptLanguageSupportFailure::Cancelled);
            }
            state.environment_failure = None;
            state.details.health = ScriptAnalysisHealth::Checking;
            state.details.indexing = None;
            state.details.resident_memory_bytes = None;
            for session in state.sessions.values_mut() {
                session.environment_failure = None;
                session.diagnostics.clear();
            }
        }
        self.set_state(ScriptLanguageServiceState::Starting);
        self.workspace
            .prepare_scratch(&self.executable_url, &self.environment)
            .map_err(|error| ScriptLanguageSupportFailure::Service(error.to_string()))?;

        let root = self.workspace.root_url();
        let mut command = ProcessCommand::new(self.executable_url.clone(), root.clone());
        let capabilities: RustAnalyzerCapabilities =
            RustAnalyzerExecutableLocator::probe_capabilities(&self.executable_url);
        command.arguments = RustAnalyzerCommandLine::arguments(&root, &capabilities);
        let mut environment: BTreeMap<String, String> = std::env::vars().collect();
        for (key, value) in &self.environment {
            environment.insert(key.clone(), value.clone());
        }
        environment.insert("COVE_LOG_RUN_ID".to_string(), LogSystem::launch().run_id);
        command.environment = environment;

        let mut configuration = LanguageServerConfiguration::new(command, root);
        // The project folder is a second root: its own Rust files and Cargo
        // workspace are analyzed in place, so the next session starts from what
        // was indexed.
        configuration.additional_workspaces = vec![self.workspace.project_root_url()];
        if let Some(connect) = self.connect_transport.clone() {
            configuration.connect =
                Some(Box::new(move |command: &ProcessCommand| connect(command)) as ConnectHook);
        }
        let mut fallback = Map::new();
        fallback.insert(
            // D1: the flags are rustc's now, not the Swift compiler's.
            "rustcFlags".to_string(),
            json!(self.workspace.include_flags()),
        );
        if let Some(sdk_url) = self.workspace.sdk_url.clone() {
            fallback.insert(
                "sdk".to_string(),
                Value::String(sdk_url.to_string_lossy().into_owned()),
            );
        }
        // The plugin's options, plus the host's module search paths for files no
        // package describes.
        let server = LanguageCatalog::served().and_then(|language| language.server.as_ref());
        let mut options: Map<String, Value> = match server
            .and_then(|(contribution, _)| contribution.initialization_options.as_ref())
            .map(|options| options.foundation_value())
        {
            Some(Value::Object(object)) => object,
            _ => Map::new(),
        };
        options.insert("fallbackBuildSystem".to_string(), Value::Object(fallback));
        configuration.initialization_options = Some(
            serde_json::to_vec(&Value::Object(options))
                .map_err(|error| ScriptLanguageSupportFailure::Service(error.to_string()))?,
        );
        configuration.settings = match server
            .and_then(|(contribution, _)| contribution.settings.as_ref())
        {
            Some(settings) => Some(
                serde_json::to_vec(&settings.foundation_value())
                    .map_err(|error| ScriptLanguageSupportFailure::Service(error.to_string()))?,
            ),
            None => None,
        };

        let client = Arc::new(LspClient::new(configuration));
        let connection_id = diffuse_kernel::codable::new_uuid();
        {
            let mut state = self.lock();
            state.client = Some(client.clone());
            state.lifecycle.connection_id = Some(connection_id.clone());
        }
        {
            let weak = Arc::downgrade(self);
            let notification_connection = connection_id.clone();
            let notification_handler = Box::new(move |notification: LspNotification| {
                let Some(support) = Weak::upgrade(&weak) else {
                    return;
                };
                let connection = notification_connection.clone();
                // Swift hopped into a `Task`; a notification never blocks the
                // reader thread.
                std::thread::spawn(move || support.handle(&notification, &connection));
            });
            let weak = Arc::downgrade(self);
            let failure_connection = connection_id.clone();
            let failure_handler = Box::new(move |failure: LspFailure| {
                let Some(support) = Weak::upgrade(&weak) else {
                    return;
                };
                let connection = failure_connection.clone();
                std::thread::spawn(move || support.handle_failure(&failure, &connection));
            });
            client.start(Some(notification_handler), Some(failure_handler))?;
        }
        client.initialize()?;
        {
            let state = self.lock();
            if state.lifecycle.generation != generation
                || state.lifecycle.connection_id.as_deref() != Some(connection_id.as_str())
            {
                drop(state);
                client.stop();
                return Err(ScriptLanguageSupportFailure::Cancelled);
            }
        }
        let documents: Vec<(String, ScriptLanguageDocument, String)> = {
            let mut state = self.lock();
            let identifiers: Vec<String> = state.sessions.keys().cloned().collect();
            let mut documents = Vec::with_capacity(identifiers.len());
            for identifier in identifiers {
                let Some(session) = state.sessions.get_mut(&identifier) else {
                    continue;
                };
                session.sent = session.current.clone();
                session.protocol_version = 1;
                documents.push((
                    identifier,
                    session.document.clone(),
                    session.sent.string_value(),
                ));
            }
            documents
        };
        for (_identifier, document, text) in documents {
            self.open(&text, &document, 1)?;
        }
        {
            let state = self.lock();
            if state.lifecycle.generation != generation
                || state.lifecycle.connection_id.as_deref() != Some(connection_id.as_str())
                || !client.is_running()
            {
                return Err(ScriptLanguageSupportFailure::Client(
                    LspClientError::NotRunning,
                ));
            }
        }
        {
            let mut state = self.lock();
            state.lifecycle.ready_since = Some(Instant::now());
        }
        self.set_state(ScriptLanguageServiceState::Ready);

        self.start_metrics_task();
        self.start_watch_task(&connection_id);

        let pending: Vec<(String, u64)> = {
            let state = self.lock();
            state
                .sessions
                .iter()
                .filter(|(_, session)| !session.current.has_same_contents(&session.sent))
                .map(|(identifier, session)| (identifier.clone(), session.revision))
                .collect()
        };
        for (identifier, revision) in pending {
            self.send_change(&identifier, revision);
        }
        Ok(())
    }

    fn start_metrics_task(self: &Arc<Self>) {
        let cancel = Arc::new(AtomicBool::new(false));
        let thread_cancel = cancel.clone();
        let weak = Arc::downgrade(self);
        let handle = std::thread::Builder::new()
            .name("script-language-metrics".to_string())
            .spawn(move || {
                while !thread_cancel.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_secs(2));
                    if thread_cancel.load(Ordering::SeqCst) {
                        return;
                    }
                    let Some(support) = Weak::upgrade(&weak) else {
                        return;
                    };
                    support.refresh_memory_usage();
                }
            })
            .expect("script language metrics thread");
        let mut state = self.lock();
        cancel_task(&mut state.metrics_task);
        state.metrics_task = Some(CancellableTask::new(cancel, handle));
    }

    fn start_watch_task(self: &Arc<Self>, connection_id: &str) {
        let root = self.workspace.project_root_url();
        let served = LanguageCatalog::served();
        let extensions: BTreeSet<String> = served
            .map(|language| language.language.extensions.iter().cloned().collect())
            .unwrap_or_default();
        let names: BTreeSet<String> = served
            .and_then(|language| language.server.as_ref())
            .and_then(|(contribution, _)| contribution.watched_files.clone())
            .map(|names| names.into_iter().collect())
            .unwrap_or_default();
        let cancel = Arc::new(AtomicBool::new(false));
        let thread_cancel = cancel.clone();
        let weak = Arc::downgrade(self);
        let connection = connection_id.to_string();
        let handle = std::thread::Builder::new()
            .name("script-language-watch".to_string())
            .spawn(move || {
                let mut previous = ScriptWatchedFiles::scan(&root, &extensions, &names);
                while !thread_cancel.load(Ordering::SeqCst) {
                    std::thread::sleep(Duration::from_secs(2));
                    if thread_cancel.load(Ordering::SeqCst) {
                        return;
                    }
                    let next = ScriptWatchedFiles::scan(&root, &extensions, &names);
                    let changes = previous.changes(&next);
                    previous = next;
                    if changes.is_empty() {
                        continue;
                    }
                    let Some(support) = Weak::upgrade(&weak) else {
                        return;
                    };
                    support.notify_watched_files(&changes, &connection);
                }
            })
            .expect("script language watch thread");
        let mut state = self.lock();
        cancel_task(&mut state.watch_task);
        state.watch_task = Some(CancellableTask::new(cancel, handle));
    }

    fn set_state(&self, new_state: ScriptLanguageServiceState) {
        let mut deliveries = Vec::new();
        {
            let mut state = self.lock();
            Self::set_state_locked(&mut state, &mut deliveries, new_state);
        }
        self.deliver(deliveries);
    }

    fn set_state_locked(
        state: &mut SupportState,
        deliveries: &mut Vec<Delivery>,
        new_state: ScriptLanguageServiceState,
    ) {
        if state.lifecycle.state == new_state {
            return;
        }
        state.lifecycle.state = new_state.clone();
        let logger = LogSystem::logger("com.cove.editor.lsp");
        match &new_state {
            ScriptLanguageServiceState::Inactive => {
                logger.log(&LogEvent::new(Level::Info, "Rust language server stopped"))
            }
            ScriptLanguageServiceState::Starting => {
                logger.log(&LogEvent::new(Level::Info, "Rust language server starting"))
            }
            ScriptLanguageServiceState::Ready => {
                logger.log(&LogEvent::new(Level::Info, "Rust language server ready"))
            }
            ScriptLanguageServiceState::Unavailable(message) => logger.log(&LogEvent::new(
                Level::Warning,
                format!("Rust language server unavailable: {message}"),
            )),
        }
        match &new_state {
            ScriptLanguageServiceState::Unavailable(message) => {
                state.details.health = ScriptAnalysisHealth::Degraded(message.clone());
                Self::record_language_log_locked(
                    state,
                    deliveries,
                    message,
                    ScriptLanguageLogLevel::Error,
                );
            }
            _ => {
                if new_state != ScriptLanguageServiceState::Ready {
                    state.details.health = ScriptAnalysisHealth::Checking;
                    state.details.indexing = None;
                }
                Self::record_language_log_locked(
                    state,
                    deliveries,
                    &Self::state_description(&new_state),
                    ScriptLanguageLogLevel::Info,
                );
            }
        }
        state.state_revision = state.state_revision.wrapping_add(1);
        if let Some(handler) = state.lifecycle.on_state_change.clone() {
            deliveries.push(Delivery::State(
                handler,
                ScriptLanguageServiceUpdate::new(state.state_revision, new_state),
            ));
        }
    }

    /// `String(describing:)` for the states that reach the log.
    fn state_description(state: &ScriptLanguageServiceState) -> String {
        match state {
            ScriptLanguageServiceState::Inactive => "inactive".to_string(),
            ScriptLanguageServiceState::Starting => "starting".to_string(),
            ScriptLanguageServiceState::Ready => "ready".to_string(),
            ScriptLanguageServiceState::Unavailable(message) => {
                format!("unavailable({message})")
            }
        }
    }

    fn deliver(&self, deliveries: Vec<Delivery>) {
        for delivery in deliveries {
            match delivery {
                Delivery::State(handler, update) => handler(update),
                Delivery::Details(handler, details) => handler(details),
                Delivery::Diagnostics(handler, update) => handler(update),
            }
        }
    }

    fn handle_failure(self: &Arc<Self>, failure: &LspFailure, connection_id: &str) {
        let mut deliveries = Vec::new();
        {
            let mut state = self.lock();
            if state.lifecycle.connection_id.as_deref() != Some(connection_id) {
                return;
            }
            state.lifecycle.connection_id = None;
            for session in state.sessions.values_mut() {
                cancel_task(&mut session.change_task);
            }
            if let Some(ready_since) = state.lifecycle.ready_since
                && ready_since.elapsed() >= RECOVERY_WINDOW
            {
                state.lifecycle.recovery_attempt = 0;
            }
            state.lifecycle.ready_since = None;
            Self::set_state_locked(
                &mut state,
                &mut deliveries,
                ScriptLanguageServiceState::Unavailable(failure.message()),
            );
        }
        self.deliver(deliveries);
        self.schedule_recovery();
    }

    fn schedule_recovery(self: &Arc<Self>) {
        const DELAYS: [Duration; 3] = [
            Duration::from_millis(500),
            Duration::from_secs(2),
            Duration::from_secs(5),
        ];
        let (delay, generation) = {
            let mut state = self.lock();
            let attempt = state.lifecycle.recovery_attempt as usize;
            if attempt >= DELAYS.len() || state.sessions.is_empty() {
                return;
            }
            let delay = DELAYS[attempt];
            state.lifecycle.recovery_attempt += 1;
            (delay, state.lifecycle.generation.clone())
        };
        let cancel = Arc::new(AtomicBool::new(false));
        let thread_cancel = cancel.clone();
        let weak = Arc::downgrade(self);
        cancel_task(&mut self.lock().recovery_task);
        let handle = std::thread::Builder::new()
            .name("script-language-recovery".to_string())
            .spawn(move || {
                std::thread::sleep(delay);
                if thread_cancel.load(Ordering::SeqCst) {
                    return;
                }
                let Some(support) = Weak::upgrade(&weak) else {
                    return;
                };
                support.recover(&generation);
            })
            .expect("script language recovery thread");
        self.lock().recovery_task = Some(CancellableTask::new(cancel, handle));
    }

    fn recover(self: &Arc<Self>, generation: &str) {
        {
            let mut state = self.lock();
            if state.lifecycle.generation != generation {
                return;
            }
            state.recovery_task = None;
        }
        match self.connect(generation) {
            Ok(()) => {}
            Err(error) => {
                if self.lock().lifecycle.generation != generation {
                    return;
                }
                self.set_state(ScriptLanguageServiceState::Unavailable(error.to_string()));
                // A transport failure has already scheduled its next attempt.
                if self.lock().recovery_task.is_none() {
                    self.schedule_recovery();
                }
            }
        }
    }

    /// Pushes an edit, debounced so bursts of keystrokes collapse into one
    /// `didChange` notification.
    pub fn update(self: &Arc<Self>, script_id: &str, text: TextBuffer, revision: u64) {
        let ready;
        {
            let mut state = self.lock();
            ready = state.lifecycle.state == ScriptLanguageServiceState::Ready;
            let Some(session) = state.sessions.get_mut(script_id) else {
                return;
            };
            if revision <= session.revision {
                return;
            }
            session.current = text;
            session.revision = revision;
            session.diagnostics.clear();
            cancel_task(&mut session.change_task);
            if ready {
                session.change_task = Some(self.spawn_change_task(script_id, revision));
            }
        }
        // The language server owns the open document overlay. Shadow files are
        // serialized at workspace synchronization, never on each keystroke.
    }

    fn spawn_change_task(self: &Arc<Self>, script_id: &str, revision: u64) -> CancellableTask {
        let cancel = Arc::new(AtomicBool::new(false));
        let thread_cancel = cancel.clone();
        let weak = Arc::downgrade(self);
        let script_id = script_id.to_string();
        let handle = std::thread::Builder::new()
            .name("script-language-change".to_string())
            .spawn(move || {
                std::thread::sleep(CHANGE_DEBOUNCE);
                if thread_cancel.load(Ordering::SeqCst) {
                    return;
                }
                let Some(support) = Weak::upgrade(&weak) else {
                    return;
                };
                support.send_change(&script_id, revision);
            })
            .expect("script language change thread");
        CancellableTask::new(cancel, handle)
    }

    /// Location the language server knows this script by — the shadow copy, not
    /// the project file the user sees.
    pub fn shadow_uri(&self, script_id: &str) -> Option<PathBuf> {
        self.lock()
            .sessions
            .get(script_id)
            .map(|session| session.document.analysis_url.clone())
    }

    /// The editor's latest text for a script, as the server will see it.
    pub(crate) fn current_text(&self, script_id: &str) -> Option<TextBuffer> {
        self.lock()
            .sessions
            .get(script_id)
            .map(|session| session.current.clone())
    }

    // MARK: - Semantic queries

    pub fn hover(
        self: &Arc<Self>,
        script_id: &str,
        position: ScriptLanguagePosition,
    ) -> Result<Option<ScriptHoverResult>, ScriptLanguageSupportFailure> {
        let payload = self.query(Query::Hover, script_id, position)?;
        Ok(ScriptLanguageReplies::parse_hover(payload.as_deref()))
    }

    pub fn completion(
        self: &Arc<Self>,
        script_id: &str,
        position: ScriptLanguagePosition,
        trigger_character: Option<&str>,
    ) -> Result<ScriptCompletionResult, ScriptLanguageSupportFailure> {
        let payload = self.query(
            Query::Completion {
                trigger_character: trigger_character.map(str::to_string),
            },
            script_id,
            position,
        )?;
        Ok(ScriptLanguageReplies::parse_completion(payload.as_deref()))
    }

    /// Fills in documentation the list left out to stay small.
    pub fn resolve_completion(
        &self,
        item: ScriptCompletionItem,
    ) -> Result<ScriptCompletionItem, ScriptLanguageSupportFailure> {
        let Some(resolution) = item.resolution.clone() else {
            return Ok(item);
        };
        let (client, connection_id) = {
            let state = self.lock();
            if state.lifecycle.state != ScriptLanguageServiceState::Ready {
                return Ok(item);
            }
            match state.client.clone() {
                Some(client) => (client, state.lifecycle.connection_id.clone()),
                None => return Ok(item),
            }
        };
        let Ok(params) = serde_json::from_slice::<Value>(&resolution) else {
            return Ok(item);
        };
        let payload = client.request("completionItem/resolve", Some(params), QUERY_TIMEOUT)?;
        let connection_matches = self.lock().lifecycle.connection_id == connection_id;
        if !connection_matches {
            return Ok(item);
        }
        let Some(payload) = payload else {
            return Ok(item);
        };
        let Ok(object) = serde_json::from_slice::<Value>(&payload) else {
            return Ok(item);
        };
        if !object.is_object() {
            return Ok(item);
        }
        let Some(resolved) = ScriptLanguageReplies::parse_completion_item(&object) else {
            return Ok(item);
        };
        let mut next = item;
        next.documentation = resolved.documentation;
        let detail = resolved.detail.or_else(|| next.detail.clone());
        next.detail = detail;
        next.resolution = None;
        Ok(next)
    }

    /// Resolves `goto definition`, re-mapping the shadow workspace URIs back
    /// onto project script identifiers so the editor can decide whether the
    /// target is something it can show.
    pub fn definition(
        self: &Arc<Self>,
        script_id: &str,
        position: ScriptLanguagePosition,
    ) -> Result<Vec<ScriptDefinitionLocation>, ScriptLanguageSupportFailure> {
        let payload = self.query(Query::Definition, script_id, position)?;
        Ok(ScriptLanguageReplies::parse_definition(payload.as_deref())
            .into_iter()
            .map(|location| {
                let script_id = Self::script_identifier_in(&self.lock(), &location.document_uri);
                ScriptDefinitionLocation::new(location.document_uri, script_id, location.span)
            })
            .collect())
    }

    // MARK: - Internals

    pub fn language_service_details(&self) -> ScriptLanguageServiceDetails {
        self.lock().details.clone()
    }

    pub fn reference_document(
        &self,
        document_uri: &str,
    ) -> Result<Option<String>, ScriptLanguageSupportFailure> {
        // D1: rust-analyzer serves virtual documents under its own scheme.
        let scheme = document_uri.split_once(':').map(|(scheme, _)| scheme);
        if !scheme.is_some_and(|scheme| scheme.eq_ignore_ascii_case("rust-analyzer"))
            || !self.is_ready()
        {
            return Ok(None);
        }
        let (client, connection_id) = {
            let state = self.lock();
            match state.client.clone() {
                Some(client) => (client, state.lifecycle.connection_id.clone()),
                None => return Ok(None),
            }
        };
        let payload = client.request(
            "workspace/getReferenceDocument",
            Some(json!({ "uri": document_uri })),
            QUERY_TIMEOUT,
        )?;
        let connection_matches = self.lock().lifecycle.connection_id == connection_id;
        if !connection_matches {
            return Ok(None);
        }
        let Some(payload) = payload else {
            return Ok(None);
        };
        let Ok(object) = serde_json::from_slice::<Value>(&payload) else {
            return Ok(None);
        };
        let Some(content) = object.get("content").and_then(Value::as_str) else {
            return Ok(None);
        };
        if content.len() > MAXIMUM_REFERENCE_DOCUMENT_BYTES {
            return Err(ScriptLanguageSupportError::Unavailable(
                "The generated reference document is too large to open.".to_string(),
            )
            .into());
        }
        Ok(Some(content.to_string()))
    }

    /// Test identifiers the server found in the workspace's index, leaves only:
    /// `Group/test`, the form test runners filter by.
    pub fn workspace_tests(&self) -> Result<Vec<String>, ScriptLanguageSupportFailure> {
        let (client, connection_id) = {
            let state = self.lock();
            if state.lifecycle.state != ScriptLanguageServiceState::Ready {
                return Err(LspClientError::NotRunning.into());
            }
            match state.client.clone() {
                Some(client) => (client, state.lifecycle.connection_id.clone()),
                None => return Err(LspClientError::NotRunning.into()),
            }
        };
        let payload =
            client.request("workspace/tests", Some(json!({})), Duration::from_secs(30))?;
        let connection_matches = self.lock().lifecycle.connection_id == connection_id;
        if !connection_matches {
            return Ok(Vec::new());
        }
        let Some(payload) = payload else {
            return Ok(Vec::new());
        };
        let Ok(Value::Array(items)) = serde_json::from_slice::<Value>(&payload) else {
            return Ok(Vec::new());
        };
        fn visit(item: &Value, identifiers: &mut Vec<String>) {
            let children: Vec<Value> = item
                .get("children")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            if children.is_empty()
                && let Some(id) = item.get("id").and_then(Value::as_str)
                && item.get("disabled").and_then(Value::as_bool) != Some(true)
            {
                identifiers.push(id.to_string());
            }
            for child in &children {
                visit(child, identifiers);
            }
        }
        let mut identifiers = Vec::new();
        for item in &items {
            visit(item, &mut identifiers);
        }
        Ok(identifiers)
    }

    /// Declarations across the indexed workspace whose names match `query`.
    /// Shadow copies the editor does not show are left out.
    pub fn workspace_symbols(
        &self,
        query: &str,
    ) -> Result<Vec<ScriptWorkspaceSymbol>, ScriptLanguageSupportFailure> {
        let (client, connection_id) = {
            let state = self.lock();
            if state.lifecycle.state != ScriptLanguageServiceState::Ready {
                return Err(LspClientError::NotRunning.into());
            }
            match state.client.clone() {
                Some(client) => (client, state.lifecycle.connection_id.clone()),
                None => return Err(LspClientError::NotRunning.into()),
            }
        };
        let payload = client.request(
            "workspace/symbol",
            Some(json!({ "query": query })),
            QUERY_TIMEOUT,
        )?;
        let connection_matches = self.lock().lifecycle.connection_id == connection_id;
        if !connection_matches {
            return Err(LspClientError::NotRunning.into());
        }
        Ok(
            crate::scripting::rust_analyzer::language::assistance_replies::ScriptAssistanceReplies::workspace_symbols(
                payload.as_deref(),
                200,
            )
            .into_iter()
            .filter_map(|(name, kind, container_name, uri, span)| {
                let script_id = Self::script_identifier_in(&self.lock(), &uri);
                if script_id.is_none() && uri.contains("/.cove/") {
                    return None;
                }
                Some(ScriptWorkspaceSymbol::new(
                    name,
                    kind,
                    container_name,
                    ScriptDefinitionLocation::new(uri, script_id, span),
                ))
            })
            .collect(),
        )
    }

    pub(crate) fn diagnostic_payloads(&self, script_id: &str) -> Vec<Vec<u8>> {
        self.lock()
            .sessions
            .get(script_id)
            .map(|session| session.diagnostics.clone())
            .unwrap_or_default()
    }

    pub(crate) fn semantic_request(
        self: &Arc<Self>,
        method: &str,
        script_id: &str,
        parameters: impl Fn(&str) -> serde_json::Result<Value>,
    ) -> Result<ScriptSemanticResponse, ScriptLanguageSupportFailure> {
        let (client, connection_id, uri, revisions) = {
            let state = self.lock();
            if state.lifecycle.state != ScriptLanguageServiceState::Ready {
                return Err(LspClientError::NotRunning.into());
            }
            let Some(client) = state.client.clone() else {
                return Err(LspClientError::NotRunning.into());
            };
            let Some(session) = state.sessions.get(script_id) else {
                return Err(LspClientError::NotRunning.into());
            };
            let revisions: Vec<(String, u64)> = state
                .sessions
                .iter()
                .map(|(identifier, session)| (identifier.clone(), session.revision))
                .collect();
            (
                client,
                state.lifecycle.connection_id.clone(),
                file_uri(&session.document.analysis_url),
                revisions,
            )
        };
        for (identifier, revision) in revisions {
            self.send_change(&identifier, revision);
        }
        let context = self.semantic_context();
        let params = parameters(&uri)
            .map_err(|error| ScriptLanguageSupportFailure::Service(error.to_string()))?;
        let payload = client.request(method, Some(params), QUERY_TIMEOUT)?;
        let connection_matches = self.lock().lifecycle.connection_id == connection_id;
        if !connection_matches {
            return Err(LspClientError::NotRunning.into());
        }
        self.validate_context(&context)?;
        self.mark_semantic_response(payload.as_deref(), method);
        Ok(ScriptSemanticResponse::new(payload, context))
    }

    pub(crate) fn resolve_semantic_request(
        &self,
        method: &str,
        params: &Value,
        context: &ScriptSemanticContext,
    ) -> Result<Option<Vec<u8>>, ScriptLanguageSupportFailure> {
        let (client, connection_id) = {
            let state = self.lock();
            if state.lifecycle.state != ScriptLanguageServiceState::Ready {
                return Err(LspClientError::NotRunning.into());
            }
            match state.client.clone() {
                Some(client) => (client, state.lifecycle.connection_id.clone()),
                None => return Err(LspClientError::NotRunning.into()),
            }
        };
        self.validate_context(context)?;
        let payload = client.request(method, Some(params.clone()), QUERY_TIMEOUT)?;
        let connection_matches = self.lock().lifecycle.connection_id == connection_id;
        if !connection_matches {
            return Err(LspClientError::NotRunning.into());
        }
        self.validate_context(context)?;
        Ok(payload)
    }

    fn semantic_context(&self) -> ScriptSemanticContext {
        let state = self.lock();
        let mut documents = BTreeMap::new();
        for (identifier, session) in &state.sessions {
            let document = ScriptSemanticDocument::new(
                identifier.clone(),
                session.revision,
                session.protocol_version,
            );
            documents.insert(
                ScriptSemanticContext::document_key(&file_uri(&session.document.analysis_url)),
                document.clone(),
            );
            documents.insert(
                ScriptSemanticContext::document_key(&file_uri(&session.document.source_url)),
                document,
            );
        }
        ScriptSemanticContext::with_generation(documents, Self::generation_uuid(&state))
    }

    fn validate_context(
        &self,
        context: &ScriptSemanticContext,
    ) -> Result<(), ScriptLanguageSupportFailure> {
        let state = self.lock();
        if context.generation != Self::generation_uuid(&state) {
            return Err(LspClientError::NotRunning.into());
        }
        for document in context.documents.values() {
            match state.sessions.get(&document.script_id) {
                Some(session) if session.revision == document.revision => {}
                _ => {
                    return Err(
                        ScriptLanguageEditError::StaleDocument(document.script_id.clone()).into(),
                    );
                }
            }
        }
        Ok(())
    }

    /// Swift compared `UUID` values; the lifecycle stores the canonical string.
    fn generation_uuid(state: &SupportState) -> Uuid {
        Uuid::parse(&state.lifecycle.generation).expect("service generation is a canonical UUID")
    }

    fn query(
        self: &Arc<Self>,
        query: Query,
        script_id: &str,
        position: ScriptLanguagePosition,
    ) -> Result<Option<Vec<u8>>, ScriptLanguageSupportFailure> {
        let (client, connection_id, document) = {
            let state = self.lock();
            if state.lifecycle.state != ScriptLanguageServiceState::Ready {
                return Err(LspClientError::NotRunning.into());
            }
            let Some(client) = state.client.clone() else {
                return Err(LspClientError::NotRunning.into());
            };
            let Some(session) = state.sessions.get(script_id) else {
                return Ok(None);
            };
            (
                client,
                state.lifecycle.connection_id.clone(),
                session.document.clone(),
            )
        };
        let revision = {
            let state = self.lock();
            state
                .sessions
                .get(script_id)
                .map(|session| session.revision)
                .unwrap_or(0)
        };
        self.send_change(script_id, revision);
        let uri = file_uri(&document.analysis_url);
        let (method, params): (&str, serde_json::Result<Value>) = match query {
            Query::Hover => (
                ScriptLanguageQueries::METHOD_HOVER,
                ScriptLanguageQueries::hover(&uri, position).and_then(value_from_bytes),
            ),
            Query::Definition => (
                ScriptLanguageQueries::METHOD_DEFINITION,
                ScriptLanguageQueries::definition(&uri, position).and_then(value_from_bytes),
            ),
            Query::Completion { trigger_character } => (
                ScriptLanguageQueries::METHOD_COMPLETION,
                ScriptLanguageQueries::completion(
                    &uri,
                    position,
                    CompletionTrigger::Invoked,
                    trigger_character.as_deref(),
                )
                .and_then(value_from_bytes),
            ),
        };
        let params =
            params.map_err(|error| ScriptLanguageSupportFailure::Service(error.to_string()))?;
        let outcome = client.request(method, Some(params), QUERY_TIMEOUT);
        match outcome {
            Ok(payload) => {
                let connection_matches = self.lock().lifecycle.connection_id == connection_id;
                if !connection_matches {
                    return Err(LspClientError::NotRunning.into());
                }
                self.mark_semantic_response(payload.as_deref(), method);
                Ok(payload)
            }
            // A competing index build made the answer late, not wrong. Let the
            // popup dismiss itself; the next hover will likely succeed.
            Err(LspClientError::RequestTimedOut(_)) => Ok(None),
            Err(error) => Err(ScriptLanguageSupportFailure::Client(error)),
        }
    }

    fn open(
        &self,
        text: &str,
        document: &ScriptLanguageDocument,
        version: i64,
    ) -> Result<(), ScriptLanguageSupportFailure> {
        let client = {
            let state = self.lock();
            state.client.clone()
        };
        let Some(client) = client else {
            return Err(LspClientError::NotRunning.into());
        };
        let language_id = LanguageCatalog::served()
            .map(|language| language.language.id.clone())
            .unwrap_or_else(|| "plaintext".to_string());
        let params = ScriptLanguageQueries::did_open(
            &file_uri(&document.analysis_url),
            text,
            version,
            &language_id,
        )
        .and_then(value_from_bytes)
        .map_err(|error| ScriptLanguageSupportFailure::Service(error.to_string()))?;
        client.notify("textDocument/didOpen", Some(params))?;
        Ok(())
    }

    fn send_change(self: &Arc<Self>, script_id: &str, revision: u64) {
        let prepared = {
            let state = self.lock();
            if state.lifecycle.state != ScriptLanguageServiceState::Ready {
                return;
            }
            let Some(client) = state.client.clone() else {
                return;
            };
            let Some(session) = state.sessions.get(script_id) else {
                return;
            };
            if session.revision != revision {
                return;
            }
            (
                client,
                file_uri(&session.document.analysis_url),
                session.sent.clone(),
                session.current.clone(),
                session.protocol_version + 1,
            )
        };
        let (client, uri, previous, current, version) = prepared;
        let params = match ScriptLanguageQueries::did_change(&uri, &previous, &current, version) {
            Ok(params) => params,
            Err(error) => {
                self.fail_change(LspClientError::ProtocolViolation(error.to_string()));
                return;
            }
        };
        {
            let mut state = self.lock();
            if let Some(session) = state.sessions.get_mut(script_id) {
                session.sent = current;
                if params.is_some() {
                    session.protocol_version = version;
                }
            }
        }
        let Some(params) = params else {
            return;
        };
        let outcome = serde_json::from_slice::<Value>(&params)
            .map_err(|error| LspClientError::ProtocolViolation(error.to_string()))
            .and_then(|params| client.notify("textDocument/didChange", Some(params)));
        if let Err(error) = outcome {
            self.fail_change(error);
        }
    }

    /// The session cannot safely guess which revision reached the server after
    /// a transport failure. A restart opens fresh roots.
    fn fail_change(self: &Arc<Self>, error: LspClientError) {
        let connection_id = self.lock().lifecycle.connection_id.clone();
        if let Some(connection_id) = connection_id {
            self.handle_failure(&LspFailure::new(error, String::new()), &connection_id);
        }
    }

    fn handle(&self, notification: &LspNotification, connection_id: &str) {
        let mut deliveries = Vec::new();
        {
            let mut state = self.lock();
            if state.lifecycle.connection_id.as_deref() != Some(connection_id) {
                return;
            }
            Self::handle_service_notification_locked(&mut state, &mut deliveries, notification);

            let Some((published_uri, published_version, published_diagnostics)) =
                ScriptLanguageReplies::parse_diagnostics(notification)
            else {
                drop(state);
                self.deliver(deliveries);
                return;
            };
            let key = {
                let published_key = ScriptSemanticContext::document_key(&published_uri);
                state
                    .sessions
                    .iter()
                    .find(|(_, session)| {
                        ScriptSemanticContext::document_key(&file_uri(
                            &session.document.analysis_url,
                        )) == published_key
                    })
                    .map(|(identifier, _)| identifier.clone())
            };
            let Some(key) = key else {
                drop(state);
                self.deliver(deliveries);
                return;
            };

            // Diagnostics are computed against a snapshot; results older than
            // the newest edit would otherwise undo a fix the user just typed.
            let Some(session) = state.sessions.get(&key) else {
                drop(state);
                self.deliver(deliveries);
                return;
            };
            if !session.current.has_same_contents(&session.sent) {
                drop(state);
                self.deliver(deliveries);
                return;
            }
            if let Some(published_version) = published_version
                && published_version < session.protocol_version
            {
                drop(state);
                self.deliver(deliveries);
                return;
            }
            let source_revision = session.revision;

            if let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(&notification.params)
                && let Some(Value::Array(diagnostics)) = object.get("diagnostics")
            {
                let payloads: Vec<Vec<u8>> = diagnostics
                    .iter()
                    .filter_map(|diagnostic| serde_json::to_vec(diagnostic).ok())
                    .collect();
                if let Some(session) = state.sessions.get_mut(&key) {
                    session.diagnostics = payloads;
                }
            }
            let failure = published_diagnostics
                .iter()
                .find(|diagnostic| Self::is_environment_failure(&diagnostic.message))
                .map(|diagnostic| diagnostic.message.clone());
            if let Some(session) = state.sessions.get_mut(&key) {
                session.environment_failure = failure;
            }
            let session_failures: Vec<String> = {
                let mut failures: Vec<String> = state
                    .sessions
                    .values()
                    .filter_map(|session| session.environment_failure.clone())
                    .collect();
                failures.sort();
                failures
            };
            let reason = state
                .environment_failure
                .clone()
                .or_else(|| session_failures.first().cloned());
            if let Some(reason) = reason {
                state.details.health = ScriptAnalysisHealth::Degraded(reason.clone());
                Self::record_language_log_locked(
                    &mut state,
                    &mut deliveries,
                    &reason,
                    ScriptLanguageLogLevel::Error,
                );
            } else {
                if matches!(state.details.health, ScriptAnalysisHealth::Degraded(_)) {
                    state.details.health = ScriptAnalysisHealth::Checking;
                }
                Self::publish_details_locked(&mut state, &mut deliveries);
            }
            let diagnostics: Vec<ScriptLanguageDiagnostic> = published_diagnostics
                .into_iter()
                .map(|mut diagnostic| {
                    for relation in &mut diagnostic.related {
                        relation.location.script_id =
                            Self::script_identifier_in(&state, &relation.location.document_uri);
                    }
                    diagnostic
                })
                .collect();
            if let Some(handler) = state.diagnostics_handler.clone() {
                deliveries.push(Delivery::Diagnostics(
                    handler,
                    ScriptLanguageDiagnosticUpdate::new(
                        key,
                        source_revision,
                        published_version,
                        diagnostics,
                    ),
                ));
            }
        }
        self.deliver(deliveries);
    }

    fn script_identifier_in(state: &SupportState, uri: &str) -> Option<String> {
        let key = ScriptSemanticContext::document_key(uri);
        state
            .sessions
            .iter()
            .find(|(_, session)| {
                ScriptSemanticContext::document_key(&file_uri(&session.document.analysis_url))
                    == key
                    || ScriptSemanticContext::document_key(&file_uri(&session.document.source_url))
                        == key
            })
            .map(|(identifier, _)| identifier.clone())
    }

    fn handle_service_notification_locked(
        state: &mut SupportState,
        deliveries: &mut Vec<Delivery>,
        notification: &LspNotification,
    ) {
        let Ok(Value::Object(object)) = serde_json::from_slice::<Value>(&notification.params)
        else {
            return;
        };
        match notification.method.as_str() {
            "window/logMessage" | "window/showMessage" | "cove/stderr" => {
                let Some(Value::String(message)) = object.get("message") else {
                    return;
                };
                if message.is_empty() {
                    return;
                }
                let level = match object.get("type").and_then(Value::as_i64) {
                    Some(1) => ScriptLanguageLogLevel::Error,
                    Some(2) => ScriptLanguageLogLevel::Warning,
                    Some(4) => ScriptLanguageLogLevel::Debug,
                    _ => ScriptLanguageLogLevel::Info,
                };
                if Self::is_environment_failure(message) {
                    state.environment_failure = Some(message.clone());
                    state.details.health = ScriptAnalysisHealth::Degraded(message.clone());
                }
                Self::record_language_log_locked(state, deliveries, message, level);
            }
            "$/progress" => {
                let Some(Value::Object(value)) = object.get("value") else {
                    return;
                };
                let Some(Value::String(kind)) = value.get("kind") else {
                    return;
                };
                if kind == "end" {
                    state.details.indexing = None;
                } else {
                    let title = value
                        .get("title")
                        .and_then(Value::as_str)
                        .map(str::to_string)
                        .or_else(|| {
                            state
                                .details
                                .indexing
                                .as_ref()
                                .map(|progress| progress.title.clone())
                        })
                        .unwrap_or_else(|| "Indexing".to_string());
                    state.details.indexing = Some(ScriptIndexProgress::new(
                        title,
                        value
                            .get("message")
                            .and_then(Value::as_str)
                            .map(str::to_string),
                        value
                            .get("percentage")
                            .and_then(Value::as_i64)
                            .map(|percentage| percentage.clamp(0, 100)),
                    ));
                }
                Self::publish_details_locked(state, deliveries);
            }
            _ => {}
        }
    }

    fn is_environment_failure(message: &str) -> bool {
        let text = message.to_lowercase();
        const PHRASES: [&str; 6] = [
            "loading the standard library failed",
            "unable to load standard library",
            "could not find module",
            // D1: `sourcekit` became `rust-analyzer`; the heuristic is unchanged.
            "internal rust-analyzer error",
            "failed to load module",
            "sdk not found",
        ];
        PHRASES.iter().any(|phrase| text.contains(phrase))
    }

    fn record_language_log_locked(
        state: &mut SupportState,
        deliveries: &mut Vec<Delivery>,
        message: &str,
        level: ScriptLanguageLogLevel,
    ) {
        state.details.record(message, level);
        if let Some(handler) = state.details_handler.clone() {
            deliveries.push(Delivery::Details(handler, state.details.clone()));
        }
    }

    fn publish_details_locked(state: &mut SupportState, deliveries: &mut Vec<Delivery>) {
        state.details.revision = state.details.revision.wrapping_add(1);
        if let Some(handler) = state.details_handler.clone() {
            deliveries.push(Delivery::Details(handler, state.details.clone()));
        }
    }

    fn refresh_memory_usage(&self) {
        if !self.is_ready() {
            return;
        }
        let bytes = self.memory_usage.as_ref().and_then(|usage| usage());
        let mut deliveries = Vec::new();
        {
            let mut state = self.lock();
            if state.details.resident_memory_bytes == bytes {
                return;
            }
            state.details.resident_memory_bytes = bytes;
            Self::publish_details_locked(&mut state, &mut deliveries);
        }
        self.deliver(deliveries);
    }

    fn mark_semantic_response(&self, payload: Option<&[u8]>, method: &str) {
        let mut deliveries = Vec::new();
        {
            let mut state = self.lock();
            if state.details.health != ScriptAnalysisHealth::Checking
                || state.environment_failure.is_some()
                || state
                    .sessions
                    .values()
                    .any(|session| session.environment_failure.is_some())
                || !ScriptLanguageSemanticEvidence::confirms_analysis(method, payload)
            {
                return;
            }
            state.details.health = ScriptAnalysisHealth::Healthy;
            Self::publish_details_locked(&mut state, &mut deliveries);
        }
        self.deliver(deliveries);
    }
}

/// `LSPJSON.data(...)` in the builder position: the client takes structural
/// JSON, the request builders emit bytes.
fn value_from_bytes(bytes: Vec<u8>) -> serde_json::Result<Value> {
    serde_json::from_slice(&bytes)
}

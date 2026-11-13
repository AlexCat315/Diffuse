//! `Editor/Sources/EditorCore/Application/Plugins/LanguageService.swift`.
//!
//! Drives the plugin-hosted language server for user scripts.
//!
//! D1 rewrite: the served plugin is the Rust support bundle (rust-analyzer +
//! cargo), so the "Swift Support is disabled" availability message becomes a
//! Rust one. The transport itself is unchanged.
//!
//! MIGRATION.md §5.5: Swift's `AsyncThrowingStream<ProcessEvent, Error>` with a
//! detached `Task` poller becomes a bounded `std::sync::mpsc` channel and a
//! dedicated thread; `NSLock` becomes `Mutex` and cancellation is an
//! `AtomicBool` token. No async runtime is used.

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, mpsc};
use std::time::Duration;

use cove_system::command::{ProcessCommand, ProcessError, ProcessEvent};
use cove_system::event_buffer::{Failure, ProcessFailure};
use diffuse_lsp::lsp::transport::LanguageServerTransport;
use diffuse_plugin::PluginError;
use diffuse_plugin::base64_data::Data;
use diffuse_plugin::contribution::languages::language_point::LanguageContributionPoint;
use diffuse_plugin::host::plugin_host_process_client::PluginHostProcessClient;
use diffuse_plugin::host::plugin_host_rpc::PluginPreparedCapabilityResult;
use diffuse_plugin::plugin_authorization::PluginExecutionBinding;
use diffuse_plugin::processes::contract::{
    Operation, PluginProcessError, PluginProcessRequest, PluginProcessUpdate,
};
use serde_json::json;

use crate::contributions::languages::LanguageCatalog;
use crate::scripting::rust_analyzer::language::script_language_models::ScriptLanguageSupportError;

/// Swift's `@Sendable () async throws -> Void`, made synchronous per §5.5.
pub type ActivationHandler = Arc<dyn Fn() -> Result<(), String> + Send + Sync>;

/// Every error `connect` and the poller can surface. Swift's `throws` was
/// untyped; the Rust port keeps the individual failure families distinct.
#[derive(Debug, thiserror::Error)]
pub enum PluginLanguageServiceError {
    #[error(transparent)]
    Support(#[from] ScriptLanguageSupportError),
    #[error(transparent)]
    Plugin(#[from] PluginError),
    #[error(transparent)]
    InvalidProcessRequest(#[from] PluginProcessError),
    #[error(transparent)]
    Process(#[from] ProcessError),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
}

struct State {
    binding: Option<PluginExecutionBinding>,
    client: Option<Arc<PluginHostProcessClient>>,
    request_activation: Option<ActivationHandler>,
    memory_bytes: Option<u64>,
}

/// Swift's `final class PluginLanguageService: @unchecked Sendable`.
///
/// Shared mutable state lives behind `Arc<Mutex<…>>` (§5.2 / §5.5), so the
/// value is `Clone + Send + Sync` and can be handed to the connect / memory
/// hooks in `ScriptAnalysisConfiguration::support`.
#[derive(Clone)]
pub struct PluginLanguageService {
    state: Arc<Mutex<State>>,
}

impl Default for PluginLanguageService {
    fn default() -> Self {
        Self::new()
    }
}

impl PluginLanguageService {
    pub fn new() -> Self {
        PluginLanguageService {
            state: Arc::new(Mutex::new(State {
                binding: None,
                client: None,
                request_activation: None,
                memory_bytes: None,
            })),
        }
    }

    /// `static let pluginID = LanguageCatalog.served?.pluginID ?? ""` — computed
    /// once, like Swift's lazy `static let`.
    pub fn plugin_id() -> &'static str {
        static PLUGIN_ID: OnceLock<String> = OnceLock::new();
        PLUGIN_ID.get_or_init(|| {
            LanguageCatalog::served()
                .map(|language| language.plugin_id.clone())
                .unwrap_or_default()
        })
    }

    /// `var requestActivation: (@Sendable () async throws -> Void)?` — setter.
    pub fn set_request_activation(&self, handler: Option<ActivationHandler>) {
        self.lock().request_activation = handler;
    }

    pub fn request_activation(&self) -> Option<ActivationHandler> {
        self.lock().request_activation.clone()
    }

    /// `var isBound: Bool { lock.withLock { binding != nil && client != nil } }`.
    pub fn is_bound(&self) -> bool {
        let state = self.lock();
        state.binding.is_some() && state.client.is_some()
    }

    /// `var residentMemoryBytes: UInt64? { lock.withLock { memoryBytes } }`.
    pub fn resident_memory_bytes(&self) -> Option<u64> {
        self.lock().memory_bytes
    }

    /// `func activateIfNeeded() async throws { if !isBound { try await
    /// requestActivation?() } }` — blocking, no async runtime (§5.5). The
    /// handler is cloned out of the lock before it runs so it can call back into
    /// `bind` without deadlocking.
    pub fn activate_if_needed(&self) -> Result<(), String> {
        if self.is_bound() {
            return Ok(());
        }
        let handler = self.lock().request_activation.clone();
        if let Some(handler) = handler {
            handler()?;
        }
        Ok(())
    }

    /// `@discardableResult func bind(_ binding:client:) -> Bool`.
    ///
    /// `client` is `Option<Arc<…>>`: Swift compared class identity (`!==`), so
    /// the Rust port compares `Arc` pointer identity. Swift's `client: … = nil`
    /// default is spelled as `None` by the caller.
    pub fn bind(
        &self,
        binding: Option<PluginExecutionBinding>,
        client: Option<Arc<PluginHostProcessClient>>,
    ) -> bool {
        let mut state = self.lock();
        let authority_changed = state.binding.as_ref().map(|value| value.authority())
            != binding.as_ref().map(|value| value.authority());
        let client_changed = match (&state.client, &client) {
            (Some(previous), Some(next)) => !Arc::ptr_eq(previous, next),
            (None, None) => false,
            _ => true,
        };
        let changed = authority_changed || client_changed;
        state.binding = binding;
        state.client = client;
        state.memory_bytes = None;
        changed
    }

    /// `func connect(_ command: ProcessCommand) throws -> LanguageServerTransport`.
    pub fn connect(
        &self,
        command: &ProcessCommand,
    ) -> Result<LanguageServerTransport, PluginLanguageServiceError> {
        let (binding, client) = {
            let state = self.lock();
            match (state.binding.clone(), state.client.clone()) {
                (Some(binding), Some(client)) => (binding, client),
                _ => {
                    return Err(ScriptLanguageSupportError::Unavailable(
                        "Rust Support is disabled or unavailable.".to_string(),
                    )
                    .into());
                }
            }
        };

        // `PluginProcessRequest(.start)` plus the manifest's first server
        // process permission and the whitelisted environment variables.
        let mut start = PluginProcessRequest::new(Operation::Start);
        start.permission = binding
            .inspection
            .manifest
            .contributes
            .decode::<LanguageContributionPoint>()
            .ok()
            .and_then(|languages| {
                languages
                    .into_iter()
                    .filter_map(|language| language.server)
                    .next()
                    .map(|server| server.process)
            });
        start.arguments = command.arguments.clone();
        let keys: BTreeSet<String> = match start.permission.as_ref() {
            Some(permission) => binding
                .authorization
                .host
                .processes
                .iter()
                .find(|process| &process.id == permission)
                .map(|process| process.environment_keys.iter().cloned().collect())
                .unwrap_or_default(),
            None => BTreeSet::new(),
        };
        for (key, value) in &command.environment {
            if keys.contains(key.as_str()) {
                start.environment.insert(key.clone(), value.clone());
            }
        }
        let handle = invoke(&client, &binding, &start)?.handle;

        // `AsyncThrowingStream<ProcessEvent, Error>.makeStream(bufferingPolicy:
        // .bufferingOldest(64))` → bounded mpsc channel plus a poller thread.
        let (sender, receiver) = mpsc::sync_channel::<Result<ProcessEvent, Failure>>(64);
        let cancelled = Arc::new(AtomicBool::new(false));
        let finished = Arc::new(AtomicBool::new(false));

        let poller_cancelled = Arc::clone(&cancelled);
        let poller_sender = sender.clone();
        let poller_client = Arc::clone(&client);
        let poller_binding = binding.clone();
        let poller_handle = handle.clone();
        // `[weak self]`: memory updates are skipped once the service is gone.
        let weak_state = Arc::downgrade(&self.state);
        std::thread::Builder::new()
            .name("plugin-language-service-poller".to_string())
            .spawn(move || {
                let outcome: Result<(), PluginLanguageServiceError> = (|| {
                    while !poller_cancelled.load(Ordering::Acquire) {
                        let mut poll = PluginProcessRequest::new(Operation::Poll);
                        poll.handle = Some(poller_handle.clone());
                        let update = invoke(&poller_client, &poller_binding, &poll)?;
                        if let Some(state) = weak_state.upgrade() {
                            state
                                .lock()
                                .unwrap_or_else(|error| error.into_inner())
                                .memory_bytes = update.resident_memory_bytes;
                        }
                        let mut events = Vec::new();
                        if !update.stdout.is_empty() {
                            events.push(ProcessEvent::Stdout(update.stdout.0));
                        }
                        if !update.stderr.is_empty() {
                            events.push(ProcessEvent::Stderr(update.stderr.0));
                        }
                        for event in events {
                            match poller_sender.try_send(Ok(event)) {
                                Ok(()) => {}
                                // `.dropped` → `throw ProcessError.outputLimit`.
                                Err(mpsc::TrySendError::Full(_)) => {
                                    return Err(ProcessError::OutputLimit.into());
                                }
                                // `.terminated` — the stream's consumer is gone.
                                Err(mpsc::TrySendError::Disconnected(_)) => return Ok(()),
                            }
                        }
                        if let Some(failure) = update.failure {
                            return Err(ScriptLanguageSupportError::Unavailable(failure).into());
                        }
                        if let Some(status) = update.exit_status {
                            let _ = poller_sender.try_send(Ok(ProcessEvent::Exited(status)));
                            break;
                        }
                        std::thread::sleep(Duration::from_millis(20));
                    }
                    Ok(())
                })();
                if let Err(error) = outcome {
                    // `continuation.finish(throwing: error)`.
                    let failure: Failure = Arc::new(as_process_failure(&error));
                    let _ = poller_sender.send(Err(failure));
                }
                // `continuation.finish()` — dropping the last sender closes the stream.
                drop(poller_sender);
            })
            .expect("plugin language service poller thread");

        let stream = ProcessEventStream {
            receiver,
            cancelled: Arc::clone(&cancelled),
            finished: Arc::clone(&finished),
        };

        // 8192-byte chunked writes to the plugin-hosted process stdin.
        let write_client = Arc::clone(&client);
        let write_binding = binding.clone();
        let write_handle = handle.clone();
        let write = move |data: &[u8]| -> Result<(), ProcessFailure> {
            let mut offset = 0;
            while offset < data.len() {
                let end = usize::min(offset + 8192, data.len());
                let mut request = PluginProcessRequest::new(Operation::Write);
                request.handle = Some(write_handle.clone());
                request.input = Some(Data::from(&data[offset..end]));
                invoke(&write_client, &write_binding, &request)
                    .map_err(|error| as_process_failure(&error))?;
                offset = end;
            }
            Ok(())
        };

        let stop_client = Arc::clone(&client);
        let stop_binding = binding.clone();
        let stop_handle = handle.clone();
        let stop_cancelled = Arc::clone(&cancelled);
        let stop_finished = Arc::clone(&finished);
        let stop = move || {
            stop_cancelled.store(true, Ordering::Release);
            let mut request = PluginProcessRequest::new(Operation::Stop);
            request.handle = Some(stop_handle.clone());
            // `_ = try? invoke(stop)` — errors are swallowed.
            let _ = invoke(&stop_client, &stop_binding, &request);
            stop_finished.store(true, Ordering::Release);
        };

        drop(sender);
        Ok(LanguageServerTransport::new(Box::new(stream), write, stop))
    }

    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }
}

/// The `@Sendable (PluginProcessRequest) throws -> PluginProcessUpdate` closure
/// Swift captured inside `connect`.
fn invoke(
    client: &PluginHostProcessClient,
    binding: &PluginExecutionBinding,
    request: &PluginProcessRequest,
) -> Result<PluginProcessUpdate, PluginLanguageServiceError> {
    let encoded = serde_json::to_vec(request)?;
    // `String(decoding: encoded, as: UTF8.self)` is the lossy, non-throwing form.
    let request_text = String::from_utf8_lossy(&encoded).into_owned();
    let input = serde_json::to_vec(&json!({ "request": request_text }))?;
    let capability_id = format!("{}.language-server", binding.plugin_id());
    let result = client.prepare_capability(binding, &capability_id, &input, None)?;
    let PluginPreparedCapabilityResult::Read(data) = result else {
        return Err(PluginProcessError::InvalidRequest.into());
    };
    Ok(serde_json::from_slice(&data)?)
}

fn as_process_failure(error: &PluginLanguageServiceError) -> ProcessFailure {
    match error {
        PluginLanguageServiceError::Process(process_error) => {
            ProcessFailure::Process(*process_error)
        }
        other => ProcessFailure::Io(std::io::Error::other(other.to_string())),
    }
}

/// Iterator over the poller's channel — the Rust shape of
/// `AsyncThrowingStream<ProcessEvent, Error>` (§5.5). A short receive timeout
/// lets `stop` finish the stream immediately, as `continuation.finish()` did.
struct ProcessEventStream {
    receiver: mpsc::Receiver<Result<ProcessEvent, Failure>>,
    cancelled: Arc<AtomicBool>,
    finished: Arc<AtomicBool>,
}

impl Iterator for ProcessEventStream {
    type Item = Result<ProcessEvent, Failure>;

    fn next(&mut self) -> Option<Self::Item> {
        loop {
            match self.receiver.recv_timeout(Duration::from_millis(10)) {
                Ok(item) => return Some(item),
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    if self.finished.load(Ordering::Acquire) {
                        return None;
                    }
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => return None,
            }
        }
    }
}

impl Drop for ProcessEventStream {
    fn drop(&mut self) {
        // `continuation.onTermination = { _ in poller.cancel() }`.
        self.cancelled.store(true, Ordering::Release);
    }
}

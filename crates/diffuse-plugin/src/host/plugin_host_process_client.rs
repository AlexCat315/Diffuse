//! Owns the DiffusePluginHost process lifetime.
//!
//! Ported from `Engine/Sources/PluginRuntime/Host/PluginHostProcessClient.swift`.
//! Framing consumes the shared process stream with one request deadline. Swift's
//! `NSLock` becomes a `Mutex` and `ProcessSession.nextEvent(until:)` supplies the
//! deadline directly (MIGRATION.md §5.5).

#![cfg(any(target_os = "macos", target_os = "linux", target_os = "windows"))]

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

use cove_logging::{Level, LogEvent, LogSystem, LogValue};
use cove_system::command::{ProcessBudget, ProcessCommand, ProcessEvent};
use cove_system::session::ProcessSession;

use crate::PluginError;
use crate::base64_data::Data;
use crate::host::diagnostics::PluginHostDiagnostics;
use crate::host::host_capability_call::HostCapabilityCall;
use crate::host::plugin_host_rpc::{
    PluginHostFrameCodec, PluginHostMethod, PluginHostRequest, PluginHostResponse,
    PluginPreparedCapabilityResult, PluginQuerySnapshot,
};
use crate::plugin_authorization::{
    PluginAuthorizationRecord, PluginExecutionBinding, PluginInspection,
};
use crate::processes::contract::PluginProcessContext;

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginHostClientError {
    #[error("could not launch DiffusePluginHost: {0}")]
    LaunchFailed(String),
    #[error("DiffusePluginHost pipe communication failed")]
    CommunicationFailed,
    #[error("DiffusePluginHost did not respond before the request deadline")]
    TimedOut,
    #[error("DiffusePluginHost restarted; invalidate plugin plans at generation {0}")]
    HostRestarted(u64),
    #[error("DiffusePluginHost returned a mismatched response id")]
    MismatchedResponse,
    #[error("DiffusePluginHost rejected the request: {0}")]
    RequestRejected(String),
}

type InvalidationCallback = Box<dyn Fn(u64) + Send + Sync>;
type HostCallHandler = Box<
    dyn Fn(&crate::host::plugin_host_rpc::PluginHostServiceCall) -> Result<Vec<u8>, PluginError>
        + Send
        + Sync,
>;

struct Session {
    session: ProcessSession,
    pending: Vec<u8>,
    diagnostics: PluginHostDiagnostics,
}

/// Owns the host lifetime. Framing consumes the shared process stream with one
/// request deadline.
pub struct PluginHostProcessClient {
    executable_url: PathBuf,
    launch_arguments: Vec<String>,
    // UI validation must never wait for the request lock: an in-flight request
    // can call back into that UI.
    generation: AtomicU64,
    pub on_invalidation: Option<InvalidationCallback>,
    pub on_host_call: Option<HostCallHandler>,
    state: Mutex<ClientState>,
}

struct ClientState {
    session: Option<Session>,
    did_restart: bool,
}

impl PluginHostProcessClient {
    pub fn new(
        executable_url: PathBuf,
        launch_arguments: Vec<String>,
        on_invalidation: Option<InvalidationCallback>,
    ) -> Self {
        PluginHostProcessClient {
            executable_url,
            launch_arguments,
            generation: AtomicU64::new(0),
            on_invalidation,
            on_host_call: None,
            state: Mutex::new(ClientState {
                session: None,
                did_restart: false,
            }),
        }
    }

    pub fn executable_url(&self) -> &Path {
        &self.executable_url
    }

    pub fn launch_arguments(&self) -> &[String] {
        &self.launch_arguments
    }

    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::Acquire)
    }

    pub fn call(
        &self,
        request: &PluginHostRequest,
        timeout_milliseconds: u64,
    ) -> Result<PluginHostResponse, PluginError> {
        let mut invalidation: Option<u64> = None;
        let outcome = self.call_locked(request, timeout_milliseconds, &mut invalidation);
        if let (Err(_), Some(generation)) = (&outcome, invalidation)
            && let Some(callback) = &self.on_invalidation
        {
            callback(generation);
        }
        outcome
    }

    fn call_locked(
        &self,
        request: &PluginHostRequest,
        timeout_milliseconds: u64,
        invalidation: &mut Option<u64>,
    ) -> Result<PluginHostResponse, PluginError> {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let inner = (|| -> Result<PluginHostResponse, PluginError> {
            if state
                .session
                .as_ref()
                .is_some_and(|session| !session.session.is_running())
            {
                return Err(PluginHostClientError::CommunicationFailed.into());
            }
            if state.session.is_none() {
                self.launch(&mut state)?;
            }
            if state.session.is_none() {
                return Err(PluginHostClientError::CommunicationFailed.into());
            }
            let deadline = Instant::now() + Duration::from_millis(timeout_milliseconds);
            let frame = PluginHostFrameCodec::encode(request)?;
            write_session(&mut state, &frame)?;
            loop {
                let header = read_exactly(&mut state, 4, deadline)?;
                let length =
                    u32::from_be_bytes([header[0], header[1], header[2], header[3]]) as usize;
                if length > PluginHostFrameCodec::MAXIMUM_FRAME_BYTES {
                    return Err(PluginHostClientError::CommunicationFailed.into());
                }
                let mut frame = header;
                frame.extend_from_slice(&read_exactly(&mut state, length, deadline)?);
                let response: PluginHostResponse = PluginHostFrameCodec::decode(&frame)?;
                if response.id != request.id {
                    return Err(PluginHostClientError::MismatchedResponse.into());
                }
                if let Some(host_call) = response.host_call.clone() {
                    let mut reply = PluginHostRequest::new(PluginHostMethod::HostResult);
                    reply.id = request.id.clone();
                    match self.on_host_call.as_ref() {
                        Some(handler) => match handler(&host_call) {
                            Ok(data) => reply.input = Some(Data::from_bytes(data)),
                            Err(error) => reply.host_error = Some(error.to_string()),
                        },
                        None => {
                            reply.host_error = Some(
                                crate::host::bun_runtime::BunRuntimeError::Rejected(
                                    "Host service is unavailable".to_string(),
                                )
                                .to_string(),
                            );
                        }
                    }
                    let frame = PluginHostFrameCodec::encode(&reply)?;
                    write_session(&mut state, &frame)?;
                    continue;
                }
                return Ok(response);
            }
        })();
        match inner {
            Ok(response) => Ok(response),
            Err(error) => {
                let mut metadata = std::collections::BTreeMap::new();
                metadata.insert("error".to_string(), LogValue::String(error.to_string()));
                LogSystem::logger("com.cove.plugin.transport").log(
                    &LogEvent::new(Level::Error, "Plugin transport failed").with_metadata(metadata),
                );
                self.stop_locked(&mut state, false);
                let generation = self.generation.fetch_add(1, Ordering::AcqRel) + 1;
                if !state.did_restart {
                    state.did_restart = true;
                    let _ = self.launch(&mut state);
                }
                *invalidation = Some(generation);
                Err(PluginHostClientError::HostRestarted(generation).into())
            }
        }
    }

    pub fn stop(&self) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if state.session.is_some() {
            self.generation.fetch_add(1, Ordering::AcqRel);
        }
        self.stop_locked(&mut state, true);
    }

    fn launch(&self, state: &mut ClientState) -> Result<(), PluginError> {
        let directory = std::env::current_dir()
            .map_err(|error| PluginHostClientError::LaunchFailed(error.to_string()))?;
        let mut command = ProcessCommand::new(self.executable_url.clone(), directory);
        command.arguments = self.launch_arguments.clone();
        command.environment = std::env::vars().collect();
        command
            .environment
            .insert("COVE_LOG_RUN_ID".to_string(), LogSystem::launch().run_id);
        let mut budget = ProcessBudget::new();
        budget.output_bytes = PluginHostFrameCodec::MAXIMUM_FRAME_BYTES + 4;
        budget.pending_input_bytes = PluginHostFrameCodec::MAXIMUM_FRAME_BYTES + 4;
        budget.lifetime_milliseconds = None;
        match ProcessSession::new(&command, budget) {
            Ok(session) => {
                state.session = Some(Session {
                    session,
                    pending: Vec::new(),
                    diagnostics: PluginHostDiagnostics::new(),
                });
                Ok(())
            }
            Err(error) => Err(PluginHostClientError::LaunchFailed(error.to_string()).into()),
        }
    }

    fn stop_locked(&self, state: &mut ClientState, graceful: bool) {
        if let (true, Some(session)) = (graceful, state.session.as_ref()) {
            session.session.close_input();
            let deadline = Instant::now() + Duration::from_millis(1_500);
            while session.session.is_running() && Instant::now() < deadline {
                if session.session.next_event(Some(deadline)).is_err() {
                    break;
                }
            }
        }
        if let Some(mut session) = state.session.take() {
            session.session.cancel();
            session.diagnostics.finish();
        }
    }
}

impl Drop for PluginHostProcessClient {
    fn drop(&mut self) {
        if let Ok(mut state) = self.state.lock()
            && let Some(mut session) = state.session.take()
        {
            session.session.cancel();
            session.diagnostics.finish();
        }
    }
}

fn write_session(state: &mut ClientState, frame: &[u8]) -> Result<(), PluginError> {
    let Some(session) = state.session.as_mut() else {
        return Err(PluginHostClientError::CommunicationFailed.into());
    };
    session
        .session
        .write(frame)
        .map_err(|error| PluginError::Io(std::io::Error::other(error.to_string())))
}

fn read_exactly(
    state: &mut ClientState,
    count: usize,
    deadline: Instant,
) -> Result<Vec<u8>, PluginError> {
    if state.session.is_none() {
        return Err(PluginHostClientError::CommunicationFailed.into());
    }
    loop {
        {
            let session = state.session.as_mut().expect("checked above");
            if session.pending.len() >= count {
                let result = session.pending[..count].to_vec();
                session.pending.drain(..count);
                return Ok(result);
            }
        }
        if Instant::now() >= deadline {
            return Err(PluginHostClientError::TimedOut.into());
        }
        let session = state.session.as_mut().expect("checked above");
        let event = session
            .session
            .next_event(Some(deadline))
            .map_err(|_| PluginError::from(PluginHostClientError::TimedOut))?;
        let pid = session.session.process_identifier();
        match event {
            Some(ProcessEvent::Stdout(data)) => session.pending.extend_from_slice(&data),
            Some(ProcessEvent::Stderr(data)) => session.diagnostics.consume(&data, pid, false),
            Some(ProcessEvent::StderrClosed) => session.diagnostics.finish(),
            Some(ProcessEvent::StdoutClosed) | Some(ProcessEvent::Exited(_)) | None => {
                return Err(PluginHostClientError::CommunicationFailed.into());
            }
        }
    }
}

impl PluginHostProcessClient {
    pub fn inspect_plugin(&self, plugin_url: &Path) -> Result<PluginInspection, PluginError> {
        let mut request = PluginHostRequest::new(PluginHostMethod::ValidatePackage);
        request.plugin_path = Some(plugin_url.to_string_lossy().into_owned());
        let response = self.call(&request, 7_000)?;
        let payload = accepted_payload(&response)?;
        Ok(serde_json::from_slice(&payload)?)
    }

    /// Loads only an already-authorised inspection and returns a binding to the
    /// exact host generation that accepted it.
    pub fn load_plugin(
        &self,
        plugin_url: &Path,
        authorization: &PluginAuthorizationRecord,
        process_context: Option<PluginProcessContext>,
    ) -> Result<PluginExecutionBinding, PluginError> {
        let mut request = PluginHostRequest::new(PluginHostMethod::Load);
        request.plugin_path = Some(plugin_url.to_string_lossy().into_owned());
        request.authorization = Some(authorization.clone());
        request.process_context = process_context;
        let response = self.call(&request, 7_000)?;
        let payload = accepted_payload(&response)?;
        let inspection: PluginInspection = serde_json::from_slice(&payload)?;
        Ok(PluginExecutionBinding::new(
            plugin_url.to_string_lossy().into_owned(),
            inspection,
            authorization.clone(),
            self.generation(),
        )?)
    }

    pub fn unload_plugin(&self, plugin_url: &Path) -> Result<(), PluginError> {
        let mut request = PluginHostRequest::new(PluginHostMethod::Unload);
        request.plugin_path = Some(plugin_url.to_string_lossy().into_owned());
        let response = self.call(&request, 7_000)?;
        // The host answers a successful unload with an empty ok response.
        if !response.ok {
            return Err(PluginHostClientError::RequestRejected(
                response
                    .error
                    .unwrap_or_else(|| "unknown error".to_string()),
            )
            .into());
        }
        Ok(())
    }

    pub fn prepare_capability(
        &self,
        binding: &PluginExecutionBinding,
        capability_id: &str,
        input: &[u8],
        query_snapshot: Option<&PluginQuerySnapshot>,
    ) -> Result<PluginPreparedCapabilityResult, PluginError> {
        binding.validate(self.generation())?;
        let mut request = PluginHostRequest::new(PluginHostMethod::Prepare);
        request.plugin_path = Some(binding.plugin_path.clone());
        request.capability_id = Some(capability_id.to_string());
        request.input = Some(Data::from_bytes(input.to_vec()));
        request.query_snapshot = query_snapshot.cloned();
        request.authorization = Some(binding.authorization.clone());
        let response = self.call(&request, 7_000)?;
        let payload = accepted_payload(&response)?;
        binding.validate(self.generation())?;
        if binding.inspection.manifest.access
            == diffuse_capability::capability_contract::CapabilityAccess::Read
        {
            return Ok(PluginPreparedCapabilityResult::Read(payload));
        }
        let calls: Vec<HostCapabilityCall> = serde_json::from_slice(&payload)?;
        Ok(PluginPreparedCapabilityResult::HostCalls(calls))
    }
}

fn accepted_payload(response: &PluginHostResponse) -> Result<Vec<u8>, PluginError> {
    if !response.ok {
        return Err(PluginHostClientError::RequestRejected(
            response
                .error
                .clone()
                .unwrap_or_else(|| "unknown error".to_string()),
        )
        .into());
    }
    match &response.payload {
        Some(payload) => Ok(payload.0.clone()),
        None => Err(PluginHostClientError::CommunicationFailed.into()),
    }
}

/// `Set<String>.isSubset(of:)` used by the package loader; kept here because the
/// host client is the only consumer that needs it.
pub fn is_subset(left: &BTreeSet<String>, right: &BTreeSet<String>) -> bool {
    left.is_subset(right)
}

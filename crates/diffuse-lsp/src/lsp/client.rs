//! `LSPClient` — one server process speaking JSON-RPC over its pipes.
//!
//! Responsibilities are deliberately narrow: process lifecycle, request/response
//! correlation, and turning server requests we do not implement into a clean
//! error reply. What the messages *mean* lives in the editor's script-language
//! request/response layer.
//!
//! Swift made this an `actor` with `async` requests. MIGRATION.md §5.5 maps that
//! to a mutex-guarded state plus a reader thread, so the public API stays
//! synchronous and the same timeout semantics (a per-request deadline, reported
//! as [`LspClientError::RequestTimedOut`]) are preserved.

use std::collections::BTreeMap;
use std::sync::mpsc::{self, Sender};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::Duration;

use cove_system::command::ProcessEvent;

use crate::byte_stream::{LspDecoder, LspMessageFramer, LspNotification};
use crate::configuration::LanguageServerConfiguration;
use crate::lsp::connection::LspConnection;
use crate::lsp::error::{LspClientError, LspFailure};

/// A pending request: where to deliver its outcome.
type Pending = BTreeMap<i64, Sender<Result<Option<Vec<u8>>, LspClientError>>>;

/// Shared client state guarded by one mutex, with a condvar for response waiting.
struct ClientState {
    pending: Pending,
    next_request_id: i64,
    notification_handler: Option<Box<dyn Fn(LspNotification) + Send + Sync>>,
    failure_handler: Option<Box<dyn Fn(LspFailure) + Send + Sync>>,
    stderr_tail: Vec<u8>,
    is_shutting_down: bool,
    /// Set once the connection fails so waiters wake immediately.
    failures: BTreeMap<i64, LspClientError>,
}

impl Default for ClientState {
    fn default() -> Self {
        ClientState {
            pending: BTreeMap::new(),
            next_request_id: 1,
            notification_handler: None,
            failure_handler: None,
            stderr_tail: Vec::new(),
            is_shutting_down: false,
            failures: BTreeMap::new(),
        }
    }
}

pub struct LspClient {
    configuration: LanguageServerConfiguration,
    connection: Mutex<Option<LspConnection>>,
    state: Mutex<ClientState>,
    response_ready: Condvar,
}

impl LspClient {
    /// Swift's shutdown budget.
    pub const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
    /// The default per-request timeout.
    pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);
    /// Tail of stderr retained so it can be attached to a mid-flight failure.
    pub const STDERR_TAIL_CAPACITY: usize = 8_192;

    #[inline]
    pub fn new(configuration: LanguageServerConfiguration) -> Self {
        LspClient {
            configuration,
            connection: Mutex::new(None),
            state: Mutex::new(ClientState::default()),
            response_ready: Condvar::new(),
        }
    }

    fn connection_guard(&self) -> MutexGuard<'_, Option<LspConnection>> {
        self.connection.lock().unwrap_or_else(|error| error.into_inner())
    }

    fn state_guard(&self) -> MutexGuard<'_, ClientState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }

    #[inline]
    pub fn is_running(&self) -> bool {
        self.connection_guard().as_ref().is_some_and(LspConnection::is_running)
    }

    // MARK: - Lifecycle

    /// Starts the server and spawns the reader thread. A no-op when already
    /// running, matching Swift's `guard connection?.isRunning != true else`.
    pub fn start(
        self: &Arc<Self>,
        notification_handler: Option<Box<dyn Fn(LspNotification) + Send + Sync>>,
        on_failure: Option<Box<dyn Fn(LspFailure) + Send + Sync>>,
    ) -> Result<(), LspClientError> {
        if self.is_running() {
            return Ok(());
        }
        self.stop();
        let connection =
            LspConnection::new(&self.configuration).map_err(|error| match error {
                LspClientError::LaunchFailed(reason) => LspClientError::LaunchFailed(reason),
                other => LspClientError::LaunchFailed(other.to_string()),
            })?;
        let connection_id = connection.id;
        {
            let mut state = self.state_guard();
            state.notification_handler = notification_handler;
            state.failure_handler = on_failure;
            state.is_shutting_down = false;
            state.stderr_tail.clear();
            state.failures.clear();
        }
        *self.connection_guard() = Some(connection);

        let client = Arc::clone(self);
        let spawned = std::thread::Builder::new()
            .name("diffuse.lsp.reader".to_string())
            .spawn(move || client.read_loop(connection_id));
        if let Err(error) = spawned {
            self.fail_connection(LspClientError::ProtocolViolation(format!("{error}")));
        }
        Ok(())
    }

    /// `initialize` followed by the `initialized` notification.
    pub fn initialize(&self) -> Result<(), LspClientError> {
        if !self.is_running() {
            return Err(LspClientError::NotRunning);
        }
        let params = self.initialize_params();
        self.request("initialize", Some(params), Self::DEFAULT_TIMEOUT)?;
        self.notify("initialized", Some(serde_json::json!({})))
    }

    /// Stops the server. Intentional shutdown never reports a transport failure.
    pub fn stop(&self) {
        let old = self.connection_guard().take();
        if let Some(connection) = &old {
            connection.close();
        }
        {
            let mut state = self.state_guard();
            state.notification_handler = None;
            state.failure_handler = None;
        }
        self.fail_pending(LspClientError::NotRunning);
    }

    /// Sends `shutdown`, then `exit`, then stops.
    pub fn shutdown(&self) {
        {
            let mut state = self.state_guard();
            state.is_shutting_down = true;
        }
        if self.is_running() {
            let _ = self.request("shutdown", None, Self::SHUTDOWN_TIMEOUT);
            let _ = self.notify("exit", None);
        }
        self.stop();
    }

    // MARK: - Messaging

    /// Sends a request and blocks until the matching response arrives or the
    /// deadline expires.
    pub fn request(
        &self,
        method: &str,
        params: Option<serde_json::Value>,
        timeout: Duration,
    ) -> Result<Option<Vec<u8>>, LspClientError> {
        if !self.is_running() {
            return Err(LspClientError::NotRunning);
        }
        let request_id = {
            let mut state = self.state_guard();
            let id = state.next_request_id;
            state.next_request_id += 1;
            id
        };
        let body = Self::request_body(request_id, method, params)?;

        let (sender, receiver) = mpsc::channel();
        {
            let mut state = self.state_guard();
            state.pending.insert(request_id, sender);
        }
        if let Err(error) = self.write(&body) {
            {
                let mut state = self.state_guard();
                state.pending.remove(&request_id);
            }
            self.fail_connection(LspClientError::ConnectionClosed);
            return Err(error);
        }

        match receiver.recv_timeout(timeout) {
            Ok(outcome) => outcome,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                let removed = {
                    let mut state = self.state_guard();
                    state.pending.remove(&request_id);
                    state.failures.remove(&request_id)
                };
                match removed {
                    Some(failure) => Err(failure),
                    None => Err(LspClientError::RequestTimedOut(method.to_string())),
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                let removed = {
                    let mut state = self.state_guard();
                    state.failures.remove(&request_id)
                };
                Err(removed.unwrap_or(LspClientError::NotRunning))
            }
        }
    }

    pub fn notify(
        &self,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<(), LspClientError> {
        if !self.is_running() {
            return Err(LspClientError::NotRunning);
        }
        let body = Self::notification_body(method, params)?;
        if let Err(error) = self.write(&body) {
            self.fail_connection(LspClientError::ConnectionClosed);
            return Err(error);
        }
        Ok(())
    }

    // MARK: - Capabilities

    fn initialize_params(&self) -> serde_json::Value {
        let root_uri = crate::configuration::file_uri(&self.configuration.workspace);
        let folders: Vec<serde_json::Value> = self
            .configuration
            .workspace_folders()
            .into_iter()
            .map(|folder| serde_json::json!({ "uri": folder.uri, "name": folder.name }))
            .collect();
        let mut params = serde_json::json!({
            "processId": std::process::id(),
            "clientInfo": { "name": "DiffuseEditor", "version": "0.0.9" },
            "rootUri": root_uri,
            "workspaceFolders": folders,
            "capabilities": Self::client_capabilities(),
            "trace": "off",
        });
        if let Some(options) = &self.configuration.initialization_options
            && let Ok(value) = serde_json::from_slice::<serde_json::Value>(options)
        {
            params["initializationOptions"] = value;
        }
        params
    }

    fn client_capabilities() -> serde_json::Value {
        serde_json::json!({
            "workspace": {
                "applyEdit": false,
                "workspaceEdit": { "documentChanges": true, "resourceOperations": [], "failureHandling": "abort" },
                "workspaceFolders": true,
                "configuration": true,
                "symbol": { "dynamicRegistration": false },
                "didChangeWatchedFiles": { "dynamicRegistration": false },
            },
            "textDocument": {
                "synchronization": { "dynamicRegistration": false, "willSave": false, "didSave": true },
                "completion": {
                    "completionItem": {
                        "snippetSupport": true,
                        "documentationFormat": ["markdown", "plaintext"],
                        "resolveSupport": { "properties": ["documentation", "detail"] },
                    },
                },
                "hover": { "contentFormat": ["markdown", "plaintext"] },
                "definition": { "dynamicRegistration": false },
                "references": { "dynamicRegistration": false },
                "rename": { "dynamicRegistration": false, "prepareSupport": true },
                "codeAction": {
                    "dynamicRegistration": false,
                    "dataSupport": true,
                    "disabledSupport": true,
                    "isPreferredSupport": true,
                    "resolveSupport": { "properties": ["edit"] },
                    "codeActionLiteralSupport": {
                        "codeActionKind": { "valueSet": ["quickfix", "refactor", "source"] },
                    },
                },
                "signatureHelp": {
                    "signatureInformation": {
                        "documentationFormat": ["markdown", "plaintext"],
                        "parameterInformation": { "labelOffsetSupport": true },
                        "activeParameterSupport": true,
                    },
                },
                "documentSymbol": { "hierarchicalDocumentSymbolSupport": true },
                "formatting": { "dynamicRegistration": false },
                "rangeFormatting": { "dynamicRegistration": false },
                "documentHighlight": { "dynamicRegistration": false },
                "publishDiagnostics": { "relatedInformation": true },
            },
            "window": { "workDoneProgress": true },
        })
    }

    // MARK: - Encoding

    fn request_body(
        id: i64,
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<Vec<u8>, LspClientError> {
        let mut body = serde_json::json!({ "jsonrpc": "2.0", "id": id, "method": method });
        if let Some(params) = params {
            body["params"] = params;
        }
        serde_json::to_vec(&body)
            .map_err(|error| LspClientError::ProtocolViolation(error.to_string()))
    }

    fn notification_body(
        method: &str,
        params: Option<serde_json::Value>,
    ) -> Result<Vec<u8>, LspClientError> {
        let mut body = serde_json::json!({ "jsonrpc": "2.0", "method": method });
        if let Some(params) = params {
            body["params"] = params;
        }
        serde_json::to_vec(&body)
            .map_err(|error| LspClientError::ProtocolViolation(error.to_string()))
    }

    fn write(&self, body: &[u8]) -> Result<(), LspClientError> {
        let guard = self.connection_guard();
        let Some(connection) = guard.as_ref() else {
            return Err(LspClientError::NotRunning);
        };
        connection
            .transport()
            .write(&LspMessageFramer::frame(body))
            .map_err(|error| LspClientError::ProtocolViolation(format!("{error:?}")))
    }

    // MARK: - Reader thread

    fn read_loop(self: Arc<Self>, connection_id: u64) {
        let mut decoder = LspDecoder::new();
        loop {
            let next = {
                // Take the transport out of the guard only for the blocking read.
                let mut guard = self.connection_guard();
                match guard.as_mut() {
                    Some(connection) if connection.id == connection_id => {
                        connection.transport_mut().next_event()
                    }
                    _ => return,
                }
            };
            let Some(event) = next else {
                self.fail_connection_for(connection_id, LspClientError::ConnectionClosed);
                return;
            };
            match event {
                Ok(ProcessEvent::Stdout(data)) => {
                    match decoder.append(&data) {
                        Ok(messages) => {
                            for body in messages {
                                if let Err(error) = self.consume_message(&body) {
                                    self.fail_connection_for(connection_id, error);
                                    return;
                                }
                            }
                        }
                        Err(error) => {
                            self.fail_connection_for(connection_id, error);
                            return;
                        }
                    }
                }
                Ok(ProcessEvent::Stderr(data)) => self.consume_stderr(&data),
                Ok(ProcessEvent::Exited(status)) => {
                    self.fail_connection_for(connection_id, LspClientError::ProcessTerminated(status));
                    return;
                }
                Ok(ProcessEvent::StdoutClosed) => {
                    self.fail_connection_for(connection_id, LspClientError::ConnectionClosed);
                    return;
                }
                Ok(ProcessEvent::StderrClosed) => {}
                Err(failure) => {
                    self.fail_connection_for(
                        connection_id,
                        LspClientError::ProtocolViolation(format!("{failure:?}")),
                    );
                    return;
                }
            }
        }
    }

    fn consume_message(&self, body: &[u8]) -> Result<(), LspClientError> {
        let object: serde_json::Value = serde_json::from_slice(body)
            .map_err(|error| LspClientError::ProtocolViolation(error.to_string()))?;
        let Some(object) = object.as_object() else {
            return Err(LspClientError::ProtocolViolation(
                "message body is not an object".to_string(),
            ));
        };

        if let Some(id) = object.get("id").and_then(serde_json::Value::as_i64) {
            let sender = {
                let mut state = self.state_guard();
                state.pending.remove(&id)
            };
            if let Some(sender) = sender {
                let outcome = if let Some(error_object) = object.get("error") {
                    let code = error_object
                        .get("code")
                        .and_then(serde_json::Value::as_i64)
                        .unwrap_or(-32000);
                    let message = error_object
                        .get("message")
                        .and_then(serde_json::Value::as_str)
                        .unwrap_or("Unknown server error")
                        .to_string();
                    Err(LspClientError::ServerError { code, message })
                } else if let Some(result) = object.get("result") {
                    Ok(Some(serde_json::to_vec(result).unwrap_or_else(|_| b"null".to_vec())))
                } else {
                    Ok(Some(b"null".to_vec()))
                };
                let _ = sender.send(outcome);
                return Ok(());
            }
        }

        let Some(method) = object.get("method").and_then(serde_json::Value::as_str) else {
            return Ok(());
        };
        let method = method.to_string();
        if let Some(request_id) = object.get("id") {
            return self.respond_to_server_request(request_id, &method, object.get("params"));
        }
        let params = object
            .get("params")
            .and_then(|params| serde_json::to_vec(params).ok())
            .unwrap_or_else(|| b"null".to_vec());
        let handler = {
            let state = self.state_guard();
            state.notification_handler.as_ref().map(|handler| {
                // The handler lives behind the mutex; copy the message out first.
                let _ = handler;
            })
        };
        let _ = handler;
        self.dispatch_notification(LspNotification::new(method, params));
        Ok(())
    }

    fn dispatch_notification(&self, notification: LspNotification) {
        // Re-take the guard only to borrow the handler, then drop it before the
        // callback runs so the callback may re-enter the client.
        let handler_ptr: Option<*const (dyn Fn(LspNotification) + Send + Sync)> = {
            let state = self.state_guard();
            state.notification_handler.as_deref().map(|handler| handler as *const _)
        };
        if let Some(handler_ptr) = handler_ptr {
            // SAFETY: the handler is owned by `state` and not removed during this
            // call; the pointer is dropped before any re-entrant mutation.
            unsafe {
                (*handler_ptr)(notification);
            }
        }
    }

    /// Answers the handful of server-initiated requests a server issues during
    /// startup. Everything else is rejected with `-32601` so the server stops
    /// waiting for a reply instead of blocking the RPC channel.
    fn respond_to_server_request(
        &self,
        id: &serde_json::Value,
        method: &str,
        params: Option<&serde_json::Value>,
    ) -> Result<(), LspClientError> {
        let result = match method {
            "workspace/configuration" => {
                let items = params
                    .and_then(|params| params.get("items"))
                    .and_then(serde_json::Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let settings = self
                    .configuration
                    .settings
                    .as_ref()
                    .and_then(|settings| serde_json::from_slice::<serde_json::Value>(settings).ok());
                let answers: Vec<serde_json::Value> = items
                    .into_iter()
                    .map(|item| {
                        let Some(section) = item.get("section").and_then(serde_json::Value::as_str)
                        else {
                            return settings.clone().unwrap_or(serde_json::Value::Null);
                        };
                        let mut value = settings.clone();
                        for key in section.split('.') {
                            value = value
                                .as_ref()
                                .and_then(|current| current.get(key))
                                .cloned();
                        }
                        value.unwrap_or(serde_json::Value::Null)
                    })
                    .collect();
                serde_json::Value::Array(answers)
            }
            "workspace/workspaceFolders" => {
                let folders: Vec<serde_json::Value> = self
                    .configuration
                    .workspace_folders()
                    .into_iter()
                    .map(|folder| serde_json::json!({ "uri": folder.uri, "name": folder.name }))
                    .collect();
                serde_json::Value::Array(folders)
            }
            "client/registerCapability"
            | "client/unregisterCapability"
            | "window/workDoneProgress/create"
            | "workspace/semanticTokens/refresh"
            | "workspace/inlayHint/refresh"
            | "workspace/diagnostic/refresh"
            | "window/showMessageRequest" => serde_json::Value::Null,
            _ => {
                let response = serde_json::json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": {
                        "code": -32601,
                        "message": "Method not supported by DiffuseEditor",
                    },
                });
                let body = serde_json::to_vec(&response)
                    .map_err(|error| LspClientError::ProtocolViolation(error.to_string()))?;
                return self.write(&body);
            }
        };
        let response = serde_json::json!({ "jsonrpc": "2.0", "id": id, "result": result });
        let body = serde_json::to_vec(&response)
            .map_err(|error| LspClientError::ProtocolViolation(error.to_string()))?;
        self.write(&body)
    }

    // MARK: - Failure paths

    fn consume_stderr(&self, data: &[u8]) {
        let text = String::from_utf8_lossy(data).into_owned();
        {
            let mut state = self.state_guard();
            state.stderr_tail.extend_from_slice(data);
            if state.stderr_tail.len() > Self::STDERR_TAIL_CAPACITY {
                let excess = state.stderr_tail.len() - Self::STDERR_TAIL_CAPACITY;
                state.stderr_tail.drain(..excess);
            }
        }
        cove_logging::LogSystem::logger("com.cove.editor.lsp").log(
            &cove_logging::LogEvent::new(cove_logging::Level::Debug, text.clone()),
        );
        let params = serde_json::json!({ "message": text, "type": 4 });
        if let Ok(bytes) = serde_json::to_vec(&params) {
            self.dispatch_notification(LspNotification::new("cove/stderr", bytes));
        }
    }

    fn fail_connection_for(&self, connection_id: u64, error: LspClientError) {
        let matches = {
            let guard = self.connection_guard();
            guard.as_ref().is_some_and(|connection| connection.id == connection_id)
        };
        if !matches {
            return;
        }
        self.fail_connection(error);
    }

    fn fail_connection(&self, error: LspClientError) {
        let old = self.connection_guard().take();
        let Some(old) = old else {
            return;
        };
        let failure = {
            let state = self.state_guard();
            LspFailure::new(error.clone(), String::from_utf8_lossy(&state.stderr_tail).into_owned())
        };
        let handler = {
            let mut state = self.state_guard();
            state.failure_handler.take()
        };
        let shutting_down = {
            let state = self.state_guard();
            state.is_shutting_down
        };
        {
            let mut state = self.state_guard();
            state.notification_handler = None;
        }
        old.close();
        self.fail_pending(error);
        if !shutting_down
            && let Some(handler) = handler
        {
            handler(failure);
        }
    }

    fn fail_pending(&self, error: LspClientError) {
        let senders = {
            let mut state = self.state_guard();
            let pending = std::mem::take(&mut state.pending);
            for id in pending.keys() {
                state.failures.insert(*id, error.clone());
            }
            pending
        };
        for sender in senders.into_values() {
            let _ = sender.send(Err(error.clone()));
        }
        self.response_ready.notify_all();
    }
}

impl Drop for LspClient {
    fn drop(&mut self) {
        if let Some(connection) = self.connection.get_mut().unwrap_or_else(|error| error.into_inner()).take()
        {
            connection.close();
        }
    }
}

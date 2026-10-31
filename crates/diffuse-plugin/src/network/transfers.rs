//! HTTP transfers for plugins, performed with `cove-http`.
//!
//! Ported from `Engine/Sources/PluginRuntime/Network/Transfers.swift`. The Swift
//! file used `URLSession`; MIGRATION.md gap G4 maps that to `cove-http`, whose
//! `Client::send` blocks until the response head arrives and streams the body
//! through `Read`. Swift's `URLSession.dataTask` + `poll` pair existed so the
//! plugin host's serial request loop never waited on the network, so each
//! transfer runs on its own worker thread and publishes into `PluginHTTPUpdate`
//! behind a `Mutex`, with an `AtomicBool` standing in for `URLSessionTask.cancel`
//! (MIGRATION.md §5.5).

use std::collections::BTreeMap;
use std::io::Read;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use cove_http::{Client, ClientConfig, HttpError, Request};

use crate::base64_data::Data;
use crate::network::http::{
    PluginHTTPError, PluginHTTPMessage, PluginHTTPPermission, PluginHTTPRequest,
    PluginHTTPResponse, PluginHTTPUpdate,
};
use crate::plugin_authorization::{PluginAuthorizationRecord, PluginInspection};
use crate::uuid::Uuid;

/// Failure modes `cove-http` reports, mapped onto the Swift error vocabulary.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginHTTPTransportError {
    #[error("HTTP client rejected the request: {0}")]
    InvalidRequest(String),
    #[error("HTTP is unavailable: {0}")]
    Unavailable(String),
    #[error("HTTP request timed out")]
    TimedOut,
    #[error("HTTP request failed: {0}")]
    Failed(String),
}

impl From<HttpError> for PluginHTTPTransportError {
    fn from(error: HttpError) -> Self {
        match error {
            HttpError::Timeout => PluginHTTPTransportError::TimedOut,
            HttpError::UnsupportedUrl(message) | HttpError::InvalidRequest(message) => {
                PluginHTTPTransportError::InvalidRequest(message)
            }
            HttpError::Unavailable(message) => PluginHTTPTransportError::Unavailable(message),
            other => PluginHTTPTransportError::Failed(other.to_string()),
        }
    }
}

struct TransferState {
    response: Option<PluginHTTPResponse>,
    failure: Option<String>,
}

struct Transfer {
    handle: Uuid,
    maximum_bytes: usize,
    state: Mutex<TransferState>,
    cancelled: AtomicBool,
    worker: Mutex<Option<std::thread::JoinHandle<()>>>,
}

impl Transfer {
    fn new(maximum_bytes: usize) -> Arc<Transfer> {
        Arc::new(Transfer {
            handle: Uuid::new(),
            maximum_bytes,
            state: Mutex::new(TransferState {
                response: None,
                failure: None,
            }),
            cancelled: AtomicBool::new(false),
            worker: Mutex::new(None),
        })
    }

    fn finish(&self, response: PluginHTTPResponse) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if state.response.is_none() && state.failure.is_none() {
            state.response = Some(response);
        }
    }

    fn fail(&self, message: impl Into<String>) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        if state.response.is_none() && state.failure.is_none() {
            state.failure = Some(message.into());
        }
    }

    fn poll(&self) -> (PluginHTTPUpdate, bool) {
        let state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        let mut update = PluginHTTPUpdate::new(self.handle.clone());
        if let Some(response) = &state.response {
            update.status = Some(response.status);
            update.headers = response.headers.clone();
            let body_len = response.body.len();
            update.body =
                Data::from_bytes(response.body.0[..body_len.min(self.maximum_bytes)].to_vec());
            update.failure = if body_len > self.maximum_bytes {
                Some(PluginHTTPError::ResponseTooLarge.to_string())
            } else {
                None
            };
            return (update, true);
        }
        if let Some(failure) = &state.failure {
            update.failure = Some(failure.clone());
            return (update, true);
        }
        (update, false)
    }

    fn is_finished(&self) -> bool {
        let state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        state.response.is_some() || state.failure.is_some()
    }

    fn cancel(&self) {
        self.cancelled.store(true, Ordering::Release);
    }
}

struct Mount {
    permissions: Vec<PluginHTTPPermission>,
}

/// Performs HTTP for plugins without blocking the plugin host's serial request
/// loop: `start` returns a handle immediately and `poll` reports completion. The
/// package declares reachable hosts in `plugin.json`; anything outside them is
/// refused before a socket opens.
pub struct PluginHTTPService {
    state: Mutex<ServiceState>,
}

struct ServiceState {
    mounts: BTreeMap<String, Mount>,
    transfers: BTreeMap<Uuid, Arc<Transfer>>,
}

impl PluginHTTPService {
    pub fn new() -> Self {
        PluginHTTPService {
            state: Mutex::new(ServiceState {
                mounts: BTreeMap::new(),
                transfers: BTreeMap::new(),
            }),
        }
    }

    pub fn mount(
        &self,
        inspection: &PluginInspection,
        authorization: &PluginAuthorizationRecord,
    ) -> Result<(), PluginError> {
        if !authorization.is_still_valid(inspection) {
            return Err(
                crate::plugin_authorization::PluginAuthorizationError::NoLongerValid.into(),
            );
        }
        let permissions = inspection.manifest.host.http.clone();
        self.lock()
            .mounts
            .insert(inspection.manifest.id.clone(), Mount { permissions });
        Ok(())
    }

    /// Cancels every in-flight transfer the plugin owns; unload must not leave a
    /// socket open past the package's lifetime.
    pub fn unmount(&self, plugin_id: &str) {
        let removed: Vec<Arc<Transfer>> = {
            let mut state = self.lock();
            if state.mounts.remove(plugin_id).is_none() {
                return;
            }
            let abandoned: Vec<Uuid> = state
                .transfers
                .values()
                .filter(|transfer| !transfer.is_finished())
                .map(|transfer| transfer.handle.clone())
                .collect();
            abandoned
                .into_iter()
                .filter_map(|handle| state.transfers.remove(&handle))
                .collect()
        };
        for transfer in removed {
            transfer.cancel();
            transfer.fail(PluginHTTPError::NotAuthorized.to_string());
        }
    }

    pub fn response(&self, plugin_id: &str, request: &[u8]) -> Result<Vec<u8>, PluginError> {
        let decoded: PluginHTTPRequest = serde_json::from_slice(request)?;
        let update = self.perform(plugin_id, &decoded)?;
        Ok(serde_json::to_vec(&update)?)
    }

    pub fn perform(
        &self,
        plugin_id: &str,
        request: &PluginHTTPRequest,
    ) -> Result<PluginHTTPUpdate, PluginError> {
        match request.operation {
            crate::network::http::Operation::Start => {
                let Some(message) = request.message.as_ref() else {
                    return Err(PluginHTTPError::InvalidRequest.into());
                };
                let Some(permission) = self.permission(plugin_id, message)? else {
                    return Err(PluginHTTPError::NotAuthorized.into());
                };
                let transfer = Transfer::new(permission.maximum_response_bytes.max(0) as usize);
                {
                    let mut state = self.lock();
                    let active = state
                        .transfers
                        .values()
                        .filter(|transfer| !transfer.is_finished())
                        .count();
                    if active >= 8 || state.transfers.len() >= 32 {
                        return Err(PluginHTTPError::TransferLimit.into());
                    }
                    state
                        .transfers
                        .insert(transfer.handle.clone(), transfer.clone());
                }
                self.start(transfer.clone(), message, &permission)?;
                Ok(PluginHTTPUpdate::new(transfer.handle.clone()))
            }
            crate::network::http::Operation::Poll => {
                let Some(handle) = request.handle.as_ref() else {
                    return Err(PluginHTTPError::InvalidHandle.into());
                };
                let transfer = self
                    .lock()
                    .transfers
                    .get(handle)
                    .cloned()
                    .ok_or(PluginHTTPError::InvalidHandle)?;
                let (update, finished) = transfer.poll();
                if finished {
                    self.lock().transfers.remove(handle);
                }
                Ok(update)
            }
            crate::network::http::Operation::Cancel => {
                let Some(handle) = request.handle.as_ref() else {
                    return Err(PluginHTTPError::InvalidHandle.into());
                };
                let transfer = self
                    .lock()
                    .transfers
                    .remove(handle)
                    .ok_or(PluginHTTPError::InvalidHandle)?;
                transfer.cancel();
                transfer.fail(PluginHTTPError::RequestFailed("cancelled".to_string()).to_string());
                Ok(PluginHTTPUpdate::new(handle.clone()))
            }
        }
    }

    fn permission(
        &self,
        plugin_id: &str,
        message: &PluginHTTPMessage,
    ) -> Result<Option<PluginHTTPPermission>, PluginError> {
        let mount_permissions = {
            let state = self.lock();
            let Some(mount) = state.mounts.get(plugin_id) else {
                return Err(PluginHTTPError::NotAuthorized.into());
            };
            mount.permissions.clone()
        };
        let Some((scheme, host)) = parse_scheme_and_host(&message.url) else {
            return Err(PluginHTTPError::InvalidRequest.into());
        };
        let Some(permission) = mount_permissions
            .iter()
            .find(|permission| permission.allows(&host))
        else {
            return Err(PluginHTTPError::DomainDenied(host).into());
        };
        let scheme_allowed = scheme == "https"
            || (scheme == "http" && permission.allows_insecure_localhost && is_loopback(&host));
        if !scheme_allowed {
            return Err(PluginHTTPError::SchemeDenied(scheme).into());
        }
        if let Some(body) = &message.body
            && body.len() as i64 > permission.maximum_response_bytes
        {
            return Err(PluginHTTPError::ResponseTooLarge.into());
        }
        Ok(Some(permission.clone()))
    }

    fn start(
        &self,
        transfer: Arc<Transfer>,
        message: &PluginHTTPMessage,
        permission: &PluginHTTPPermission,
    ) -> Result<(), PluginError> {
        let mut outgoing = Request::new(message.method.raw_value(), message.url.clone());
        if let Some(body) = &message.body {
            outgoing = outgoing.body(body.0.clone());
        }
        for (name, value) in &message.headers {
            outgoing = outgoing.header(name.clone(), value.clone());
        }
        let maximum_bytes = permission.maximum_response_bytes.max(0) as usize;
        // `URLRequest.timeoutInterval` is per request; cove-http takes it on the
        // client, so each transfer gets the permission's own deadline.
        let client = Client::new(ClientConfig {
            timeout: std::time::Duration::from_millis(
                u64::try_from(permission.timeout_milliseconds.max(0)).unwrap_or(0),
            ),
            ..ClientConfig::default()
        });
        let worker_transfer = transfer.clone();
        let worker = std::thread::Builder::new()
            .name("diffuse.plugin.http".into())
            .spawn(move || {
                let transfer = worker_transfer;
                if transfer.cancelled.load(Ordering::Acquire) {
                    return;
                }
                match client.send(outgoing) {
                    Ok(mut response) => {
                        let status = i64::from(response.status);
                        let headers: BTreeMap<String, String> = response
                            .headers
                            .iter()
                            .map(|(name, value)| (name.to_string(), value.to_string()))
                            .collect();
                        let mut body = Vec::new();
                        if response
                            .body()
                            .take(maximum_bytes as u64 + 1)
                            .read_to_end(&mut body)
                            .is_err()
                        {
                            transfer.fail(PluginHTTPError::InvalidRequest.to_string());
                            return;
                        }
                        if body.len() > maximum_bytes {
                            transfer.fail(PluginHTTPError::ResponseTooLarge.to_string());
                            return;
                        }
                        transfer.finish(PluginHTTPResponse {
                            status,
                            headers,
                            body: Data::from_bytes(body),
                        });
                    }
                    Err(error) => transfer.fail(PluginHTTPTransportError::from(error).to_string()),
                }
            })
            .map_err(|error| PluginError::Io(std::io::Error::other(error.to_string())))?;
        *transfer
            .worker
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = Some(worker);
        Ok(())
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, ServiceState> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }
}

impl Default for PluginHTTPService {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for PluginHTTPService {
    fn drop(&mut self) {
        let state = self
            .state
            .get_mut()
            .unwrap_or_else(|error| error.into_inner());
        for transfer in state.transfers.values() {
            transfer.cancel();
        }
    }
}

/// The scheme and host `URL(string:)` exposed, lowercased.
fn parse_scheme_and_host(url: &str) -> Option<(String, String)> {
    let (scheme, rest) = url.split_once("://")?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    let host = authority.rsplit('@').next().unwrap_or_default();
    let host = host.split(':').next().unwrap_or_default();
    if scheme.is_empty() || host.is_empty() {
        return None;
    }
    Some((scheme.to_lowercase(), host.to_lowercase()))
}

fn is_loopback(host: &str) -> bool {
    host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
}

use crate::PluginError;

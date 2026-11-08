//! The Bun-backed plugin runtime.
//!
//! Ported from `Engine/Sources/PluginRuntime/Host/BunRuntime.swift`. The native
//! broker retains authorization and host services; Bun owns plugin state. Bun is
//! a trusted desktop extension process, not a WebAssembly security sandbox.
//!
//! Swift used `Process()`/`ProcessSession` and an `AsyncSequence`; here the
//! session is `cove_system::session::ProcessSession` and each call reads one
//! event at a time until the deadline, which is the same blocking protocol
//! without an async runtime (MIGRATION.md §5.5).

use std::collections::BTreeMap;

use cove_system::command::{ProcessBudget, ProcessCommand, ProcessEvent};
use cove_system::session::ProcessSession;
use diffuse_capability::capsule_schema::validate_capability_input;

use crate::PluginError;
use crate::contract::plugin_manifest::{PluginImportPermission, PluginResourceLimits};
use crate::contract::plugin_package::ValidatedPluginPackage;
use crate::host::plugin_host_rpc::PluginQuerySnapshot;
use crate::host::plugin_host_rpc::PluginQuerySnapshotError;
use crate::network::transfers::PluginHTTPService;
use crate::plugin_authorization::PluginCapabilityValidationError;
use crate::processes::service::PluginProcessService;
use crate::uuid::Uuid;

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum BunRuntimeError {
    #[error("Bun runtime is missing. Run cove studio plugins prepare.")]
    Unavailable,
    #[error("Bun plugin: {0}")]
    Rejected(String),
    #[error("Bun plugin protocol failed")]
    ProtocolFailure,
}

/// Host services a Bun invocation may call back into.
pub struct PluginHostServiceCall {
    pub permission: String,
    pub request: Vec<u8>,
}

type HostCall = Box<dyn Fn(PluginHostServiceCall) -> Result<Vec<u8>, PluginError> + Send + Sync>;

pub struct BunPluginRuntime {
    pub runtime_version: String,
    processes: PluginProcessService,
    http: PluginHTTPService,
    sessions: BTreeMap<String, BunSession>,
    pub host_call: Option<HostCall>,
}

impl BunPluginRuntime {
    pub fn new(processes: PluginProcessService, http: PluginHTTPService) -> Self {
        BunPluginRuntime {
            runtime_version: "1.4.4".to_string(),
            processes,
            http,
            sessions: BTreeMap::new(),
            host_call: None,
        }
    }

    pub fn validate_component(
        &self,
        package: &ValidatedPluginPackage,
        _limits: &PluginResourceLimits,
    ) -> Result<(), PluginError> {
        package.require_runtime()?;
        if package
            .manifest
            .runtime
            .as_ref()
            .map(|runtime| runtime.engine.as_str())
            != Some("bun")
        {
            return Err(BunRuntimeError::Unavailable.into());
        }
        Ok(())
    }

    pub fn prepare(
        &mut self,
        package: &ValidatedPluginPackage,
        capability_id: &str,
        input: &[u8],
        query_snapshot: Option<&PluginQuerySnapshot>,
        limits: &PluginResourceLimits,
    ) -> Result<Vec<u8>, PluginError> {
        let component = package.require_runtime()?.clone();
        let Some(entry) = component
            .contract
            .capability_inputs
            .iter()
            .find(|entry| format!("{}.{}", package.manifest.id, entry.name) == capability_id)
        else {
            return Err(PluginCapabilityValidationError::UnknownCapability(
                capability_id.to_string(),
            )
            .into());
        };
        let value: serde_json::Value = serde_json::from_slice(input)?;
        validate_capability_input(&value, &package.input_schema(entry))
            .map_err(|error| BunRuntimeError::Rejected(error.to_string()))?;

        let plugin_id = package.manifest.id.clone();
        if !self.sessions.contains_key(&plugin_id) {
            let mut session = BunSession::new()?;
            let storage = application_support_directory()
                .join("Diffuse/Plugins")
                .join(&plugin_id);
            let mut load_arguments: BTreeMap<String, serde_json::Value> = BTreeMap::new();
            load_arguments.insert("method".to_string(), serde_json::json!("load"));
            load_arguments.insert("pluginID".to_string(), serde_json::json!(plugin_id));
            load_arguments.insert(
                "storageDirectory".to_string(),
                serde_json::json!(storage.to_string_lossy()),
            );
            load_arguments.insert(
                "sdkDirectory".to_string(),
                serde_json::json!(
                    plugin_sdk_directory()
                        .map(|path| path.to_string_lossy().into_owned())
                        .unwrap_or_default()
                ),
            );
            load_arguments.insert(
                "entry".to_string(),
                serde_json::json!(component.entry_url.to_string_lossy()),
            );
            let names = session.call(&load_arguments, limits, &|_, _| {
                Err(BunRuntimeError::Rejected(
                    "Host services are only available during an invocation".to_string(),
                )
                .into())
            })?;
            let exported: Vec<String> = serde_json::from_slice(&names)?;
            let mut exported = exported;
            exported.sort();
            let mut expected: Vec<String> = component
                .contract
                .capability_inputs
                .iter()
                .map(|entry| entry.name.clone())
                .collect();
            expected.sort();
            if exported != expected {
                session.stop();
                return Err(BunRuntimeError::Rejected(
                    "Exports differ from capabilities.json".to_string(),
                )
                .into());
            }
            self.sessions.insert(plugin_id.clone(), session);
        }

        let entry_name = entry.name.clone();
        let manifest_imports = package.manifest.imports.clone();
        let operation = self.sessions.get_mut(&plugin_id).map(|session| {
            let mut arguments: BTreeMap<String, serde_json::Value> = BTreeMap::new();
            arguments.insert("method".to_string(), serde_json::json!("invoke"));
            arguments.insert("name".to_string(), serde_json::json!(entry_name));
            arguments.insert("input".to_string(), value.clone());
            let result = session.call(&arguments, limits, &|permission, request| {
                let Some(granted) = PluginImportPermission::from_raw_value(&permission) else {
                    return Err(PluginQuerySnapshotError::ImportNotGranted(permission).into());
                };
                if !manifest_imports.contains(&granted) {
                    return Err(PluginQuerySnapshotError::ImportNotGranted(permission).into());
                }
                match granted {
                    PluginImportPermission::Process => {
                        self.processes.response(&plugin_id, &entry_name, &request)
                    }
                    PluginImportPermission::Http => self.http.response(&plugin_id, &request),
                    PluginImportPermission::Editor | PluginImportPermission::Service => {
                        let Some(host_call) = self.host_call.as_ref() else {
                            return Err(BunRuntimeError::Rejected(
                                "Host service is unavailable".to_string(),
                            )
                            .into());
                        };
                        host_call(PluginHostServiceCall {
                            permission: permission.clone(),
                            request,
                        })
                    }
                    // Snapshot imports need the editor's payload.
                    _ => {
                        let Some(snapshot) = query_snapshot else {
                            return Err(PluginQuerySnapshotError::MissingPayload(granted).into());
                        };
                        let granted_imports: std::collections::BTreeSet<PluginImportPermission> =
                            manifest_imports.iter().copied().collect();
                        Ok(snapshot.response(&permission, &request, &granted_imports)?)
                    }
                }
            });
            (result, session.failed())
        });
        let Some((result, failed)) = operation else {
            return Err(BunRuntimeError::ProtocolFailure.into());
        };
        match result {
            Ok(payload) => Ok(payload),
            Err(error) => {
                // A timed out or broken stream cannot be reused; never consume a
                // late response as the next call.
                if failed && let Some(mut session) = self.sessions.remove(&plugin_id) {
                    session.stop();
                }
                Err(error)
            }
        }
    }

    pub fn interrupt(&mut self, plugin_id: &str) {
        if let Some(mut session) = self.sessions.remove(plugin_id) {
            session.shutdown();
        }
    }
}

struct BunSession {
    process: ProcessSession,
    pending: Vec<u8>,
    failed: bool,
}

impl BunSession {
    fn new() -> Result<Self, PluginError> {
        let binary = Self::executable()?;
        let runner = bun_runner_path().ok_or(BunRuntimeError::Unavailable)?;
        let directory = runner
            .parent()
            .map(|parent| parent.to_path_buf())
            .unwrap_or_else(std::env::temp_dir);
        let mut command = ProcessCommand::new(binary, directory);
        command.arguments = vec![
            "--no-install".to_string(),
            runner.to_string_lossy().into_owned(),
        ];
        // Never inherit Bun preloads, NODE_OPTIONS or project search paths.
        command.environment = std::env::vars()
            .filter(|(key, _)| !key.starts_with("BUN_") && !key.starts_with("NODE_"))
            .collect();
        let mut budget = ProcessBudget::new();
        budget.output_bytes = 384 * 1_024 * 1_024;
        budget.pending_input_bytes = 384 * 1_024 * 1_024;
        budget.lifetime_milliseconds = None;
        let process = ProcessSession::new(&command, budget)
            .map_err(|error| PluginError::Io(std::io::Error::other(error.to_string())))?;
        Ok(BunSession {
            process,
            pending: Vec::new(),
            failed: false,
        })
    }

    fn failed(&self) -> bool {
        self.failed
    }

    fn stop(&mut self) {
        self.process.cancel();
    }

    fn shutdown(&mut self) {
        if !self.failed && self.process.is_running() {
            let mut limits = PluginResourceLimits::secure_default();
            limits.preparation_timeout_milliseconds = 1_000;
            let mut arguments: BTreeMap<String, serde_json::Value> = BTreeMap::new();
            arguments.insert("method".to_string(), serde_json::json!("unload"));
            let _ = self.call(&arguments, &limits, &|_, _| {
                Err(BunRuntimeError::ProtocolFailure.into())
            });
        }
        self.stop();
    }

    fn call(
        &mut self,
        arguments: &BTreeMap<String, serde_json::Value>,
        limit: &PluginResourceLimits,
        host: &dyn Fn(String, Vec<u8>) -> Result<Vec<u8>, PluginError>,
    ) -> Result<Vec<u8>, PluginError> {
        let id = Uuid::new().to_string();
        let mut message = arguments.clone();
        message.insert("id".to_string(), serde_json::json!(id));
        let deadline = std::time::Instant::now()
            + std::time::Duration::from_millis(limit.preparation_timeout_milliseconds);
        self.write(&message)?;
        let outcome = (|| -> Result<Vec<u8>, PluginError> {
            loop {
                let reply = self.read(deadline, limit.maximum_output_bytes as usize)?;
                if reply.get("type").and_then(|value| value.as_str()) == Some("host") {
                    let request_id = reply.get("id").cloned().unwrap_or(serde_json::Value::Null);
                    let Some(permission) = reply.get("permission").and_then(|value| value.as_str())
                    else {
                        return Err(BunRuntimeError::ProtocolFailure.into());
                    };
                    let Some(request) = reply.get("request") else {
                        return Err(BunRuntimeError::ProtocolFailure.into());
                    };
                    let request_bytes = serde_json::to_vec(request)?;
                    let mut response: BTreeMap<String, serde_json::Value> = BTreeMap::new();
                    response.insert("type".to_string(), serde_json::json!("hostResult"));
                    response.insert("id".to_string(), request_id);
                    match host(permission.to_string(), request_bytes) {
                        Ok(data) => {
                            let value: serde_json::Value = serde_json::from_slice(&data)?;
                            response.insert("value".to_string(), value);
                        }
                        Err(error) => {
                            response
                                .insert("error".to_string(), serde_json::json!(error.to_string()));
                        }
                    }
                    self.write(&response)?;
                } else {
                    if reply.get("id").and_then(|value| value.as_str()) != Some(id.as_str()) {
                        return Err(BunRuntimeError::ProtocolFailure.into());
                    }
                    if let Some(error) = reply.get("error").and_then(|value| value.as_str()) {
                        return Err(BunRuntimeError::Rejected(error.to_string()).into());
                    }
                    let payload =
                        serde_json::to_vec(reply.get("value").unwrap_or(&serde_json::Value::Null))?;
                    if payload.len() > limit.maximum_output_bytes as usize {
                        return Err(
                            crate::host::plugin_host_rpc::PluginHostFrameError::FrameTooLarge
                                .into(),
                        );
                    }
                    return Ok(payload);
                }
            }
        })();
        match outcome {
            Ok(payload) => Ok(payload),
            Err(error) => {
                // A rejected call leaves the stream usable; every other failure
                // (a protocol desync or a broken pipe) poisons it, so the next
                // call must not read a late reply as its own.
                if !matches!(error, PluginError::Bun(BunRuntimeError::Rejected(_))) {
                    self.failed = true;
                    self.stop();
                }
                Err(error)
            }
        }
    }

    fn write(&mut self, value: &BTreeMap<String, serde_json::Value>) -> Result<(), PluginError> {
        let mut data = serde_json::to_vec(value)?;
        data.push(10);
        self.process
            .write(&data)
            .map_err(|error| PluginError::Io(std::io::Error::other(error.to_string())))
    }

    fn read(
        &mut self,
        deadline: std::time::Instant,
        maximum: usize,
    ) -> Result<serde_json::Value, PluginError> {
        loop {
            if let Some(newline) = self.pending.iter().position(|byte| *byte == 10) {
                let line = self.pending[..newline].to_vec();
                self.pending.drain(..=newline);
                return Ok(serde_json::from_slice(&line)?);
            }
            if self.pending.len() > maximum + 65_536 {
                return Err(
                    crate::host::plugin_host_rpc::PluginHostFrameError::FrameTooLarge.into(),
                );
            }
            let event = self
                .process
                .next_event(Some(deadline))
                .map_err(|error| PluginError::Io(std::io::Error::other(error.to_string())))?;
            match event {
                Some(ProcessEvent::Stdout(bytes)) => self.pending.extend_from_slice(&bytes),
                Some(ProcessEvent::Stderr(bytes)) => {
                    use std::io::Write as _;
                    let _ = std::io::stderr().write_all(&bytes);
                }
                Some(ProcessEvent::StderrClosed) => {}
                Some(ProcessEvent::StdoutClosed) | Some(ProcessEvent::Exited(_)) | None => {
                    return Err(BunRuntimeError::ProtocolFailure.into());
                }
            }
        }
    }

    /// `bun.exe` on Windows, `bun` elsewhere; the bundled copy first, then beside
    /// the executable, then `Tools/`, then the debug-only `vendor/` tree.
    fn executable() -> Result<std::path::PathBuf, PluginError> {
        #[cfg(target_os = "windows")]
        let name = "bun.exe";
        #[cfg(not(target_os = "windows"))]
        let name = "bun";
        let mut candidates: Vec<std::path::PathBuf> = Vec::new();
        if let Some(bundled) = bundled_resource(&format!("bun/{name}")) {
            candidates.push(bundled);
        }
        if let Ok(executable) = std::env::current_exe()
            && let Some(directory) = executable.parent()
        {
            candidates.push(directory.join(name));
            candidates.push(directory.join("Tools").join(name));
        }
        #[cfg(debug_assertions)]
        {
            // `#filePath` three levels up plus `vendor/bun/`; the crate root is
            // the Rust equivalent of the Swift source directory.
            let engine = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("..")
                .join("..");
            candidates.push(engine.join("vendor").join("bun").join(name));
        }
        candidates
            .into_iter()
            .find(|candidate| is_executable(candidate))
            .ok_or_else(|| BunRuntimeError::Unavailable.into())
    }
}

fn is_executable(path: &std::path::Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file())
    }
}

/// `Bundle.module.url(forResource:withExtension:subdirectory:)` against the
/// crate's `Resources/` directory, which MIGRATION.md §2.1 keeps beside the
/// crate.
fn bundled_resource(relative: &str) -> Option<std::path::PathBuf> {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("Resources")
        .join(relative);
    path.exists().then_some(path)
}

fn bun_runner_path() -> Option<std::path::PathBuf> {
    bundled_resource("bun-runner.js")
}

fn plugin_sdk_directory() -> Option<std::path::PathBuf> {
    bundled_resource("plugin-sdk")
}

/// `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]`.
fn application_support_directory() -> std::path::PathBuf {
    #[cfg(target_os = "macos")]
    {
        std::env::var_os("HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
            .join("Library")
            .join("Application Support")
    }
    #[cfg(target_os = "windows")]
    {
        return std::env::var_os("APPDATA")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(std::env::temp_dir);
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        std::env::var_os("XDG_DATA_HOME")
            .map(std::path::PathBuf::from)
            .unwrap_or_else(|| {
                std::env::var_os("HOME")
                    .map(std::path::PathBuf::from)
                    .unwrap_or_else(std::env::temp_dir)
                    .join(".local")
                    .join("share")
            })
    }
}

impl ValidatedPluginPackage {
    /// `package.manifest.id + "." + input.name == capabilityID` convenience used
    /// by the Bun broker.
    pub fn capability_input(
        &self,
        capability_id: &str,
    ) -> Option<&crate::contract::plugin_contract::PluginEntryContract> {
        self.runtime.as_ref().and_then(|runtime| {
            runtime
                .contract
                .capability_inputs
                .iter()
                .find(|entry| format!("{}.{}", self.manifest.id, entry.name) == capability_id)
        })
    }
}

//! Binary entry point. See MIGRATION.md §5.
//!
//! Ported from `Engine/Sources/DiffusePluginHost/main.swift`: the isolated
//! framed-RPC process that stages packages, enforces authorization and owns the
//! Bun runtime.

use std::collections::BTreeMap;
use std::fmt;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use cove_logging::{Level, LogEvent, LogSystem, LogValue, LoggingConfiguration};
use cove_system::permissions::FilePermissions;
use diffuse_capability::capability_contract::CapabilityAccess;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_capability::capsule_schema::validate_capability_input;
use diffuse_plugin::base64_data::Data;
use diffuse_plugin::contract::plugin_manifest::PluginResourceLimits;
use diffuse_plugin::contract::plugin_package::{PluginPackageLoader, ValidatedPluginPackage};
use diffuse_plugin::contract::resources::standardized;
use diffuse_plugin::contribution::registry::ContributionPointRegistry;
use diffuse_plugin::host::bun_runtime::{
    BunPluginRuntime, BunRuntimeError, PluginHostServiceCall as BunHostServiceCall,
};
use diffuse_plugin::host::host_capability_call::{HostCapabilityCall, PluginCompositionValidator};
use diffuse_plugin::host::plugin_host_rpc::{
    PluginHostFrameCodec, PluginHostFrameError, PluginHostMethod, PluginHostRequest,
    PluginHostResponse, PluginHostServiceCall,
};
use diffuse_plugin::network::transfers::PluginHTTPService;
use diffuse_plugin::plugin_authorization::{
    PluginAuthorizationError, PluginAuthorizationRecord, PluginCapabilityDiscovery,
    PluginCapabilityValidationError, PluginContractDeriver, PluginInspection,
};
use diffuse_plugin::processes::contract::PluginProcessError;
use diffuse_plugin::processes::service::PluginProcessService;
use diffuse_plugin::{PluginError, Uuid};

#[cfg(test)]
mod tests;

const LOG_LABEL: &str = "com.cove.engine.plugin";

/// Swift's `PluginHostStagingError` plus the pass-through for every error the
/// runtime layers already define. Swift's `String(describing:)` produced the
/// bare case names, which this `Display` reproduces.
#[derive(Debug)]
enum HostError {
    Plugin(PluginError),
    Validation(String),
    PackageChangedDuringStaging,
    InvalidReadResult,
}

impl fmt::Display for HostError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            HostError::Plugin(PluginError::HostFrame(error)) => {
                formatter.write_str(frame_error_description(error))
            }
            HostError::Plugin(error) => write!(formatter, "{error}"),
            HostError::Validation(message) => formatter.write_str(message),
            HostError::PackageChangedDuringStaging => {
                formatter.write_str("packageChangedDuringStaging")
            }
            HostError::InvalidReadResult => formatter.write_str("invalidReadResult"),
        }
    }
}

impl From<PluginError> for HostError {
    fn from(error: PluginError) -> Self {
        HostError::Plugin(error)
    }
}

impl From<std::io::Error> for HostError {
    fn from(error: std::io::Error) -> Self {
        HostError::Plugin(error.into())
    }
}

impl From<serde_json::Error> for HostError {
    fn from(error: serde_json::Error) -> Self {
        HostError::Plugin(error.into())
    }
}

/// Swift's frame error cases carry no `CustomStringConvertible`, so
/// `String(describing:)` emitted the case name.
fn frame_error_description(error: &PluginHostFrameError) -> &'static str {
    match error {
        PluginHostFrameError::FrameTooLarge => "frameTooLarge",
        PluginHostFrameError::IncompleteFrame => "incompleteFrame",
        PluginHostFrameError::TrailingBytes => "trailingBytes",
    }
}

/// `String(describing: request.method)` in the warning metadata.
fn method_name(method: PluginHostMethod) -> &'static str {
    match method {
        PluginHostMethod::Handshake => "handshake",
        PluginHostMethod::ValidatePackage => "validatePackage",
        PluginHostMethod::Load => "load",
        PluginHostMethod::Discover => "discover",
        PluginHostMethod::Prepare => "prepare",
        PluginHostMethod::Unload => "unload",
        PluginHostMethod::HostResult => "hostResult",
    }
}

fn rejected(id: &Uuid, message: &str) -> PluginHostResponse {
    let mut response = PluginHostResponse::new(id.clone(), false);
    response.error = Some(message.to_string());
    response
}

fn accepted(id: &Uuid, payload: Vec<u8>) -> PluginHostResponse {
    let mut response = PluginHostResponse::new(id.clone(), true);
    response.payload = Some(Data::from_bytes(payload));
    response
}

struct LoadedPlugin {
    source: ValidatedPluginPackage,
    execution_copy: ValidatedPluginPackage,
    inspection: PluginInspection,
    authorization: PluginAuthorizationRecord,
}

struct Host {
    runtime: BunPluginRuntime,
    loader: PluginPackageLoader,
    registry: CapabilityRegistry,
    limits: PluginResourceLimits,
    staging_root: PathBuf,
    loaded: BTreeMap<String, LoadedPlugin>,
    current_request_id: Arc<Mutex<Option<Uuid>>>,
}

impl Host {
    fn respond(&mut self, request: &PluginHostRequest) -> PluginHostResponse {
        match self.respond_inner(request) {
            Ok(response) => response,
            Err(error) => {
                let mut metadata = BTreeMap::new();
                metadata.insert(
                    "method".to_string(),
                    LogValue::from(method_name(request.method)),
                );
                metadata.insert("error".to_string(), LogValue::from(error.to_string()));
                LogSystem::logger(LOG_LABEL).log(
                    &LogEvent::new(Level::Warning, "Plugin request rejected")
                        .with_metadata(metadata),
                );
                rejected(&request.id, &error.to_string())
            }
        }
    }

    fn respond_inner(
        &mut self,
        request: &PluginHostRequest,
    ) -> Result<PluginHostResponse, HostError> {
        match request.method {
            PluginHostMethod::HostResult => {
                Err(PluginError::from(BunRuntimeError::ProtocolFailure).into())
            }
            PluginHostMethod::Handshake => self.handshake(request),
            PluginHostMethod::ValidatePackage => self.validate_package(request),
            PluginHostMethod::Load => self.load(request),
            PluginHostMethod::Discover => self.discover(request),
            PluginHostMethod::Prepare => self.prepare(request),
            PluginHostMethod::Unload => {
                self.unload(request);
                Ok(PluginHostResponse::new(request.id.clone(), true))
            }
        }
    }

    fn handshake(&self, request: &PluginHostRequest) -> Result<PluginHostResponse, HostError> {
        // `JSONSerialization` with `.sortedKeys`; `BTreeMap` gives the same
        // alphabetical order.
        let mut payload: BTreeMap<String, serde_json::Value> = BTreeMap::new();
        payload.insert(
            "maximum_frame_bytes".to_string(),
            serde_json::Value::from(PluginHostFrameCodec::MAXIMUM_FRAME_BYTES),
        );
        payload.insert("protocol_version".to_string(), serde_json::Value::from(6));
        payload.insert("runtime".to_string(), serde_json::Value::from("bun"));
        payload.insert(
            "runtime_mode".to_string(),
            serde_json::Value::from("trusted-extension-process"),
        );
        payload.insert(
            "runtime_version".to_string(),
            serde_json::Value::from(self.runtime.runtime_version.clone()),
        );
        payload.insert("sandboxed".to_string(), serde_json::Value::from(false));
        Ok(accepted(&request.id, serde_json::to_vec(&payload)?))
    }

    fn validate_package(
        &self,
        request: &PluginHostRequest,
    ) -> Result<PluginHostResponse, HostError> {
        let Some(path) = request.plugin_path.as_deref() else {
            return Ok(rejected(&request.id, "missing pluginPath"));
        };
        let package = self.loader.load(Path::new(path))?;
        let (execution_copy, inspection) = inspect_execution_copy(
            &self.runtime,
            &self.loader,
            &self.limits,
            &self.staging_root,
            &package,
        )?;
        let payload = serde_json::to_vec(&inspection)?;
        let _ = std::fs::remove_dir_all(&execution_copy.root_url);
        if payload.len() as i64 > self.limits.maximum_output_bytes {
            return Err(PluginError::from(PluginHostFrameError::FrameTooLarge).into());
        }
        Ok(accepted(&request.id, payload))
    }

    fn load(&mut self, request: &PluginHostRequest) -> Result<PluginHostResponse, HostError> {
        let Some(path) = request.plugin_path.as_deref() else {
            return Ok(rejected(&request.id, "missing pluginPath"));
        };
        let Some(authorization) = request.authorization.clone() else {
            return Err(PluginError::from(PluginAuthorizationError::Missing).into());
        };
        let package = self.loader.load(Path::new(path))?;
        let (execution_copy, inspection) = inspect_execution_copy(
            &self.runtime,
            &self.loader,
            &self.limits,
            &self.staging_root,
            &package,
        )?;
        if !authorization.is_still_valid(&inspection) {
            let _ = std::fs::remove_dir_all(&execution_copy.root_url);
            return Err(PluginError::from(PluginAuthorizationError::NoLongerValid).into());
        }
        if let Some(previous) = self.loaded.get(&package.manifest.id) {
            let previous_id = previous.execution_copy.manifest.id.clone();
            let previous_root = previous.execution_copy.root_url.clone();
            self.runtime.processes().unmount(&previous_id);
            self.runtime.http().unmount(&previous_id);
            self.runtime.interrupt(&previous_id);
            let _ = std::fs::remove_dir_all(previous_root);
        }
        if !package.manifest.host.processes.is_empty() {
            let Some(context) = request.process_context.clone() else {
                return Err(PluginError::from(PluginProcessError::NotAuthorized).into());
            };
            self.runtime
                .processes()
                .mount(&inspection, &authorization, context)?;
        }
        if !package.manifest.host.http.is_empty() {
            self.runtime.http().mount(&inspection, &authorization)?;
        }
        let payload = serde_json::to_vec(&inspection)?;
        self.loaded.insert(
            package.manifest.id.clone(),
            LoadedPlugin {
                source: package,
                execution_copy,
                inspection,
                authorization,
            },
        );
        Ok(accepted(&request.id, payload))
    }

    fn discover(&self, request: &PluginHostRequest) -> Result<PluginHostResponse, HostError> {
        let Some(path) = request.plugin_path.as_deref() else {
            return Ok(rejected(&request.id, "missing pluginPath"));
        };
        let package = self.loader.load(Path::new(path))?;
        let Some(loaded) = self.loaded.get(&package.manifest.id) else {
            return Ok(rejected(
                &request.id,
                "plugin must be loaded and unchanged before discovery",
            ));
        };
        if !packages_match(&loaded.source, &package) {
            return Ok(rejected(
                &request.id,
                "plugin must be loaded and unchanged before discovery",
            ));
        }
        if request.authorization.as_ref() != Some(&loaded.authorization)
            || !loaded.authorization.is_still_valid(&loaded.inspection)
        {
            return Err(PluginError::from(PluginAuthorizationError::NoLongerValid).into());
        }
        let capability_ids: Vec<String> = loaded
            .inspection
            .contracts
            .iter()
            .map(|contract| contract.id.clone())
            .collect();
        let payload = serde_json::to_vec(&PluginCapabilityDiscovery::new(capability_ids))?;
        if payload.len() as i64 > self.limits.maximum_output_bytes {
            return Err(PluginError::from(PluginHostFrameError::FrameTooLarge).into());
        }
        Ok(accepted(&request.id, payload))
    }

    fn prepare(&mut self, request: &PluginHostRequest) -> Result<PluginHostResponse, HostError> {
        let (Some(path), Some(capability_id), Some(input)) = (
            request.plugin_path.as_deref(),
            request.capability_id.as_deref(),
            request.input.as_ref(),
        ) else {
            return Ok(rejected(&request.id, "missing prepare arguments"));
        };
        let package = self.loader.load(Path::new(path))?;
        let Some(loaded) = self.loaded.get(&package.manifest.id) else {
            return Ok(rejected(
                &request.id,
                "plugin package changed after loading",
            ));
        };
        if !packages_match(&loaded.source, &package) {
            return Ok(rejected(
                &request.id,
                "plugin package changed after loading",
            ));
        }
        if request.authorization.as_ref() != Some(&loaded.authorization)
            || !loaded.authorization.is_still_valid(&loaded.inspection)
        {
            return Err(PluginError::from(PluginAuthorizationError::NoLongerValid).into());
        }
        let Some(contract) = loaded
            .inspection
            .contracts
            .iter()
            .find(|contract| contract.id == capability_id)
        else {
            return Err(
                PluginError::from(PluginCapabilityValidationError::UnknownCapability(
                    capability_id.to_string(),
                ))
                .into(),
            );
        };
        let entry_point: String = capability_id
            .chars()
            .skip(package.manifest.id.chars().count() + 1)
            .collect();
        let invocation_limits = package.limits(&entry_point, &self.limits);
        if !package.is_host_entry_point(&entry_point) {
            let value: serde_json::Value = serde_json::from_slice(input.as_slice())?;
            validate_capability_input(&value, &contract.input_schema)
                .map_err(|error| HostError::Validation(error.to_string()))?;
        }
        let raw_payload = self.runtime.prepare(
            &loaded.execution_copy,
            capability_id,
            input.as_slice(),
            request.query_snapshot.as_ref(),
            &invocation_limits,
        )?;
        if raw_payload.len() as i64 > invocation_limits.maximum_output_bytes {
            return Err(PluginError::from(PluginHostFrameError::FrameTooLarge).into());
        }
        if package.manifest.access == CapabilityAccess::Read {
            // Read results are untrusted model context and must stay valid JSON.
            if serde_json::from_slice::<serde_json::Value>(&raw_payload).is_err() {
                return Err(HostError::InvalidReadResult);
            }
            return Ok(accepted(&request.id, raw_payload));
        }
        let calls: Vec<HostCapabilityCall> = serde_json::from_slice(&raw_payload)?;
        let validated = PluginCompositionValidator::validate(
            &calls,
            &package.manifest,
            &self.registry,
            &self.limits,
        )?;
        Ok(accepted(&request.id, serde_json::to_vec(&validated)?))
    }

    fn unload(&mut self, request: &PluginHostRequest) {
        let Some(path) = request.plugin_path.as_deref() else {
            return;
        };
        let source_root = standardized(Path::new(path));
        let Some(plugin_id) = self
            .loaded
            .iter()
            .find(|(_, loaded)| loaded.source.root_url == source_root)
            .map(|(plugin_id, _)| plugin_id.clone())
        else {
            return;
        };
        if let Some(loaded) = self.loaded.remove(&plugin_id) {
            self.runtime.processes().unmount(&plugin_id);
            self.runtime.http().unmount(&plugin_id);
            self.runtime.interrupt(&loaded.execution_copy.manifest.id);
            let _ = std::fs::remove_dir_all(&loaded.execution_copy.root_url);
        }
    }
}

/// `packagesMatch`: everything except the authorization record.
fn packages_match(lhs: &ValidatedPluginPackage, rhs: &ValidatedPluginPackage) -> bool {
    let select = |package: &ValidatedPluginPackage| {
        package.runtime.as_ref().map(|runtime| {
            (
                runtime.contract.clone(),
                runtime.code_hash.clone(),
                runtime.contract_hash.clone(),
            )
        })
    };
    lhs.root_url == rhs.root_url
        && lhs.manifest == rhs.manifest
        && select(lhs) == select(rhs)
        && lhs.resource_hashes == rhs.resource_hashes
}

/// Execute only a host-owned copy. Re-hashing the copy closes the window where
/// an untrusted local package could replace `plugin.js` after validation but
/// before Bun opens it.
fn staged_execution_copy(
    loader: &PluginPackageLoader,
    staging_root: &Path,
    package: &ValidatedPluginPackage,
) -> Result<ValidatedPluginPackage, HostError> {
    let destination = staging_root.join(format!(
        "{}-{}.coveplugin",
        package.manifest.id,
        Uuid::new()
    ));
    FilePermissions::create_private_directory(&destination, false)?;
    let outcome = (|| -> Result<ValidatedPluginPackage, HostError> {
        let mut names = vec!["plugin.json", "plugin.js", "capabilities.json"];
        if !package.resource_hashes.is_empty() {
            names.push("resources");
        }
        for name in names {
            copy_item(&package.root_url.join(name), &destination.join(name))?;
        }
        let copy = loader.load(&destination)?;
        let unchanged = copy.manifest == package.manifest
            && copy.runtime.as_ref().map(|runtime| &runtime.contract)
                == package.runtime.as_ref().map(|runtime| &runtime.contract)
            && copy.runtime.as_ref().map(|runtime| &runtime.code_hash)
                == package.runtime.as_ref().map(|runtime| &runtime.code_hash)
            && copy.runtime.as_ref().map(|runtime| &runtime.contract_hash)
                == package
                    .runtime
                    .as_ref()
                    .map(|runtime| &runtime.contract_hash)
            && copy.resource_hashes == package.resource_hashes;
        if !unchanged {
            return Err(HostError::PackageChangedDuringStaging);
        }
        Ok(copy)
    })();
    match outcome {
        Ok(copy) => Ok(copy),
        Err(error) => {
            let _ = std::fs::remove_dir_all(&destination);
            Err(error)
        }
    }
}

fn inspect_execution_copy(
    runtime: &BunPluginRuntime,
    loader: &PluginPackageLoader,
    limits: &PluginResourceLimits,
    staging_root: &Path,
    package: &ValidatedPluginPackage,
) -> Result<(ValidatedPluginPackage, PluginInspection), HostError> {
    let execution_copy = staged_execution_copy(loader, staging_root, package)?;
    let outcome = (|| -> Result<PluginInspection, PluginError> {
        runtime.validate_component(&execution_copy, limits)?;
        let contracts = PluginContractDeriver::contracts(&execution_copy);
        Ok(PluginInspection::from_package(package, contracts))
    })();
    match outcome {
        Ok(inspection) => Ok((execution_copy, inspection)),
        Err(error) => {
            let _ = std::fs::remove_dir_all(&execution_copy.root_url);
            Err(error.into())
        }
    }
}

/// `FileManager.copyItem`: files are copied, directories recursively.
fn copy_item(source: &Path, destination: &Path) -> std::io::Result<()> {
    let metadata = std::fs::symlink_metadata(source)?;
    if metadata.is_dir() {
        std::fs::create_dir(destination)?;
        for entry in std::fs::read_dir(source)? {
            let entry = entry?;
            copy_item(&entry.path(), &destination.join(entry.file_name()))?;
        }
        Ok(())
    } else {
        std::fs::copy(source, destination).map(|_| ())
    }
}

fn read_exactly(count: usize) -> Result<Option<Vec<u8>>, PluginError> {
    let stdin = std::io::stdin();
    let mut handle = stdin.lock();
    let mut buffer = vec![0u8; count];
    let mut filled = 0;
    while filled < count {
        match handle.read(&mut buffer[filled..]) {
            Ok(0) => return Ok(None),
            Ok(read) => filled += read,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error.into()),
        }
    }
    Ok(Some(buffer))
}

fn read_request() -> Result<Option<PluginHostRequest>, PluginError> {
    let Some(header) = read_exactly(4)? else {
        return Ok(None);
    };
    let length = u32::from_be_bytes([header[0], header[1], header[2], header[3]]) as usize;
    if length > PluginHostFrameCodec::MAXIMUM_FRAME_BYTES {
        return Err(PluginHostFrameError::FrameTooLarge.into());
    }
    let Some(payload) = read_exactly(length)? else {
        return Err(PluginHostFrameError::IncompleteFrame.into());
    };
    let mut frame = header;
    frame.extend_from_slice(&payload);
    Ok(Some(PluginHostFrameCodec::decode(&frame)?))
}

fn write_frame(frame: &[u8]) -> Result<(), PluginError> {
    let stdout = std::io::stdout();
    let mut handle = stdout.lock();
    handle.write_all(frame)?;
    handle.flush()?;
    Ok(())
}

fn host_call(
    current_request_id: &Mutex<Option<Uuid>>,
    call: BunHostServiceCall,
) -> Result<Vec<u8>, PluginError> {
    let id = current_request_id
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .clone()
        .ok_or(BunRuntimeError::ProtocolFailure)?;
    let mut response = PluginHostResponse::new(id.clone(), true);
    response.host_call = Some(PluginHostServiceCall {
        permission: call.permission,
        request: Data::from_bytes(call.request),
    });
    write_frame(&PluginHostFrameCodec::encode(&response)?)?;
    let reply = read_request()?.ok_or(BunRuntimeError::ProtocolFailure)?;
    if reply.id != id || reply.method != PluginHostMethod::HostResult {
        return Err(BunRuntimeError::ProtocolFailure.into());
    }
    if let Some(error) = reply.host_error {
        return Err(BunRuntimeError::Rejected(error).into());
    }
    reply
        .input
        .map(|input| input.0)
        .ok_or_else(|| BunRuntimeError::ProtocolFailure.into())
}

fn log_protocol_failure(error: &PluginError) {
    let mut metadata = BTreeMap::new();
    metadata.insert("error".to_string(), LogValue::from(error.to_string()));
    LogSystem::logger(LOG_LABEL)
        .log(&LogEvent::new(Level::Error, "Plugin host protocol failed").with_metadata(metadata));
}

fn serve() {
    let staging_root = std::env::temp_dir().join(format!("DiffusePluginHost-{}", Uuid::new()));
    let _ = FilePermissions::create_private_directory(&staging_root, true);

    let registry = CapabilityRegistry::default_registry();
    let loader = PluginPackageLoader::new(
        registry.clone(),
        None,
        ContributionPointRegistry::standard(),
    );
    let limits = PluginResourceLimits::secure_default();
    let mut runtime = BunPluginRuntime::new(PluginProcessService::new(), PluginHTTPService::new());
    let current_request_id: Arc<Mutex<Option<Uuid>>> = Arc::new(Mutex::new(None));
    let host_request_id = Arc::clone(&current_request_id);
    runtime.host_call = Some(Box::new(move |call| host_call(&host_request_id, call)));

    let mut host = Host {
        runtime,
        loader,
        registry,
        limits,
        staging_root: staging_root.clone(),
        loaded: BTreeMap::new(),
        current_request_id,
    };

    loop {
        let request = match read_request() {
            Ok(Some(request)) => request,
            Ok(None) => break,
            Err(error) => {
                log_protocol_failure(&error);
                LogSystem::flush();
                break;
            }
        };
        *host
            .current_request_id
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = Some(request.id.clone());
        let response = host.respond(&request);
        let frame = match PluginHostFrameCodec::encode(&response) {
            Ok(frame) => frame,
            Err(error) => {
                log_protocol_failure(&error);
                LogSystem::flush();
                break;
            }
        };
        *host
            .current_request_id
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = None;
        if let Err(error) = write_frame(&frame) {
            log_protocol_failure(&error);
            LogSystem::flush();
            break;
        }
    }

    for plugin_id in host.loaded.keys() {
        host.runtime.processes().unmount(plugin_id);
        host.runtime.http().unmount(plugin_id);
        host.runtime.interrupt(plugin_id);
    }
    let _ = std::fs::remove_dir_all(&staging_root);
}

fn main() {
    let mut configuration = LoggingConfiguration::default();
    if let Err(error) = configuration.apply_environment(&std::env::vars().collect()) {
        cove_logging::console_write(
            Level::Error.native_index(),
            &format!("DiffusePluginHost logging configuration failed: {error}"),
        );
        std::process::exit(1);
    }
    if let Err(error) = LogSystem::bootstrap(None, configuration, None) {
        cove_logging::console_write(
            Level::Error.native_index(),
            &format!("DiffusePluginHost logging bootstrap failed: {error}"),
        );
        std::process::exit(1);
    }
    if std::env::args().count() != 1 {
        LogSystem::logger(LOG_LABEL).log(&LogEvent::new(
            Level::Error,
            "DiffusePluginHost accepts no build commands; use diffuse-plugin build",
        ));
        LogSystem::flush();
        std::process::exit(1);
    }
    serve();
    LogSystem::flush();
}

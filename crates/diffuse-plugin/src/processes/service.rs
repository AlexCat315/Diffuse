//! Native process authority for plugins.
//!
//! Ported from `Engine/Sources/PluginRuntime/Processes/Service.swift`.
//!
//! Every operation is scoped to an approved mount generation; unload invalidates
//! all its handles.

use std::collections::BTreeMap;
use std::sync::{Arc, Mutex};

use cove_system::command::{ProcessBudget, ProcessCommand};
use cove_system::session::ProcessSession;

use crate::PluginError;
use crate::base64_data::Data;
use crate::contract::host_permissions::PluginHostPermissions;
use crate::plugin_authorization::{PluginAuthorizationRecord, PluginInspection};
use crate::processes::contract::{
    Operation, PluginProcessContext, PluginProcessError, PluginProcessRequest, PluginProcessUpdate,
};
use crate::processes::entry::ProcessEntry;
use crate::uuid::Uuid;

struct Mount {
    generation: Uuid,
    permissions: PluginHostPermissions,
    context: PluginProcessContext,
}

struct State {
    mounts: BTreeMap<String, Mount>,
    processes: BTreeMap<Uuid, Arc<ProcessEntry>>,
}

pub struct PluginProcessService {
    state: Mutex<State>,
}

impl PluginProcessService {
    pub fn new() -> Self {
        PluginProcessService {
            state: Mutex::new(State {
                mounts: BTreeMap::new(),
                processes: BTreeMap::new(),
            }),
        }
    }

    pub fn mount(
        &self,
        inspection: &PluginInspection,
        authorization: &PluginAuthorizationRecord,
        context: PluginProcessContext,
    ) -> Result<(), PluginError> {
        if !authorization.is_still_valid(inspection) {
            return Err(
                crate::plugin_authorization::PluginAuthorizationError::NoLongerValid.into(),
            );
        }
        inspection
            .manifest
            .host
            .validate(&inspection.manifest.imports)?;
        self.unmount(&inspection.manifest.id);
        self.lock().mounts.insert(
            inspection.manifest.id.clone(),
            Mount {
                generation: Uuid::new(),
                permissions: inspection.manifest.host.clone(),
                context,
            },
        );
        Ok(())
    }

    pub fn unmount(&self, plugin_id: &str) {
        let removed: Vec<Arc<ProcessEntry>> = {
            let mut state = self.lock();
            let Some(mount) = state.mounts.remove(plugin_id) else {
                return;
            };
            let handles: Vec<Uuid> = state
                .processes
                .values()
                .filter(|entry| entry.generation == mount.generation)
                .map(|entry| entry.handle())
                .collect();
            let mut entries = Vec::with_capacity(handles.len());
            for handle in handles {
                if let Some(entry) = state.processes.remove(&handle) {
                    entries.push(entry);
                }
            }
            entries
        };
        for entry in removed {
            entry.session.cancel();
        }
    }

    pub fn response(
        &self,
        plugin_id: &str,
        entry_point: &str,
        request: &[u8],
    ) -> Result<Vec<u8>, PluginError> {
        if request.len() > crate::host::plugin_host_rpc::PluginQuerySnapshot::MAXIMUM_REQUEST_BYTES
        {
            return Err(PluginProcessError::InvalidRequest.into());
        }
        let input: PluginProcessRequest = serde_json::from_slice(request)?;
        let update = self.perform(plugin_id, entry_point, &input)?;
        Ok(serde_json::to_vec(&update)?)
    }

    pub fn perform(
        &self,
        plugin_id: &str,
        entry_point: &str,
        request: &PluginProcessRequest,
    ) -> Result<PluginProcessUpdate, PluginError> {
        let mut state = self.lock();
        let Some(mount) = state.mounts.get(plugin_id) else {
            return Err(PluginProcessError::NotAuthorized.into());
        };
        let generation = mount.generation.clone();
        if request.operation == Operation::Start {
            let rule = mount
                .permissions
                .processes
                .iter()
                .find(|rule| Some(&rule.id) == request.permission.as_ref())
                .filter(|rule| rule.entry_points.contains(&entry_point.to_string()))
                .cloned()
                .ok_or(PluginProcessError::NotAuthorized)?;
            let running = state
                .processes
                .values()
                .filter(|entry| entry.generation == generation)
                .count();
            if running >= 8 || state.processes.len() >= 32 {
                return Err(PluginProcessError::ProcessLimit.into());
            }
            let executable = mount
                .context
                .executables
                .get(&rule.command)
                .cloned()
                .ok_or_else(|| PluginProcessError::CommandNotBound(rule.command.clone()))?;
            if !executable.is_absolute() {
                return Err(PluginProcessError::CommandNotBound(rule.command.clone()).into());
            }
            // `request.arguments.starts(with: rule.argumentPrefix)`
            let prefix_ok = request.arguments.len() <= 128
                && request
                    .arguments
                    .iter()
                    .zip(rule.argument_prefix.iter())
                    .all(|(argument, expected)| argument == expected)
                && request.arguments.len() >= rule.argument_prefix.len()
                && (rule.allows_additional_arguments || request.arguments == rule.argument_prefix);
            if !prefix_ok {
                return Err(PluginProcessError::ArgumentsDenied.into());
            }
            let allowed: std::collections::BTreeSet<&String> =
                rule.environment_keys.iter().collect();
            if !request.environment.keys().all(|key| allowed.contains(key)) {
                return Err(PluginProcessError::EnvironmentDenied.into());
            }
            let mut command = ProcessCommand::new(executable, mount.context.workspace.clone());
            command.arguments = request.arguments.clone();
            command.environment = request
                .environment
                .iter()
                .map(|(key, value)| (key.clone(), value.clone()))
                .collect();
            let mut budget = ProcessBudget::new();
            budget.output_bytes = 33_554_432;
            budget.lifetime_milliseconds = rule
                .lifetime_milliseconds
                .and_then(|milliseconds| u64::try_from(milliseconds).ok());
            let session = ProcessSession::new(&command, budget.clone())
                .map_err(|error| PluginError::Io(std::io::Error::other(error.to_string())))?;
            let session = Arc::new(session);
            let handle = Uuid::parse(&session.id).unwrap_or_default();
            let entry = Arc::new(ProcessEntry::new(
                session,
                generation,
                rule.id.clone(),
                budget.output_bytes,
            ));
            state.processes.insert(handle.clone(), entry);
            return Ok(PluginProcessUpdate::new(handle));
        }
        let handle = request
            .handle
            .clone()
            .ok_or(PluginProcessError::InvalidHandle)?;
        let entry = state
            .processes
            .get(&handle)
            .filter(|entry| entry.generation == generation)
            .cloned()
            .ok_or(PluginProcessError::InvalidHandle)?;
        let entry_point_allowed = mount
            .permissions
            .processes
            .iter()
            .find(|rule| rule.id == entry.permission_id)
            .is_some_and(|rule| rule.entry_points.contains(&entry_point.to_string()));
        if !entry_point_allowed {
            return Err(PluginProcessError::NotAuthorized.into());
        }
        match request.operation {
            Operation::Start => unreachable!("started above"),
            Operation::Poll => {
                let update = entry.poll();
                if update.exit_status.is_some() || update.failure.is_some() {
                    state.processes.remove(&handle);
                }
                return Ok(update);
            }
            Operation::Write => {
                let data = request
                    .input
                    .as_ref()
                    .filter(|data| data.len() <= 8192)
                    .ok_or(PluginProcessError::InvalidRequest)?;
                entry
                    .session
                    .write(data.as_slice())
                    .map_err(|error| PluginError::Io(std::io::Error::other(error.to_string())))?;
            }
            Operation::CloseInput => entry.session.close_input(),
            Operation::Stop => {
                entry.session.cancel();
                state.processes.remove(&handle);
            }
        }
        Ok(PluginProcessUpdate::new(handle))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|error| error.into_inner())
    }
}

impl Default for PluginProcessService {
    fn default() -> Self {
        Self::new()
    }
}

impl Drop for PluginProcessService {
    fn drop(&mut self) {
        let state = self
            .state
            .get_mut()
            .unwrap_or_else(|error| error.into_inner());
        for entry in state.processes.values() {
            entry.session.cancel();
        }
    }
}

impl ProcessEntry {
    pub fn handle(&self) -> Uuid {
        Uuid::parse(&self.session.id).unwrap_or_default()
    }
}

/// `Data` is what the wire format carries; the helper keeps the mapping in one
/// place.
pub fn data_from(bytes: Vec<u8>) -> Data {
    Data::from_bytes(bytes)
}

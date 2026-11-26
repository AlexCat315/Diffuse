//! `Editor/Sources/EditorCore/Application/Plugins/Commands.swift`.
//!
//! Calling a plugin entry point: one capability call with the entry point's
//! input, returning whatever the package answered.

use std::collections::BTreeMap;

use diffuse_plugin::host::plugin_host_rpc::PluginPreparedCapabilityResult;

use crate::application::editor_application::EditorApplication;

/// Failures of an entry-point call.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginEntryPointError {
    #[error("{0}")]
    Runtime(String),
    #[error("The plugin returned a result this command cannot use.")]
    InvalidCommandResult,
}

impl EditorApplication {
    /// Calls `entry_point` on `plugin_id` after activating it for `event`, with
    /// the input encoded as a JSON object of the declared record fields.
    pub fn read_entry_point(
        &self,
        plugin_id: &str,
        entry_point: &str,
        event: &str,
        input: &BTreeMap<String, String>,
    ) -> Result<Vec<u8>, PluginEntryPointError> {
        let (binding, client) = self
            .plugin_session
            .runtime
            .resolve(plugin_id, event)
            .map_err(|error| PluginEntryPointError::Runtime(error.to_string()))?;
        let data = serde_json::to_vec(input)
            .map_err(|error| PluginEntryPointError::Runtime(error.to_string()))?;
        let capability_id = format!("{plugin_id}.{entry_point}");
        let result = client
            .prepare_capability(&binding, &capability_id, &data, None)
            .map_err(|error| PluginEntryPointError::Runtime(error.to_string()))?;
        match result {
            PluginPreparedCapabilityResult::Read(payload) => Ok(payload),
            PluginPreparedCapabilityResult::HostCalls(_) => {
                Err(PluginEntryPointError::InvalidCommandResult)
            }
        }
    }
}

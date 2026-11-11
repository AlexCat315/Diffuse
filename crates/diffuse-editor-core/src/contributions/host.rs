//! `Editor/Sources/EditorCore/Contributions/Host.swift`.

use std::path::Path;
use std::sync::Arc;

use diffuse_plugin::contract::host_permissions::PluginProcessPermission;
use diffuse_plugin::host::plugin_host_process_client::PluginHostProcessClient;
use diffuse_plugin::host::plugin_host_rpc::PluginPreparedCapabilityResult;
use diffuse_plugin::plugin_authorization::PluginExecutionBinding;

use crate::contributions::runtime_access::PluginRuntimeAccess;
use crate::contributions::tool::ContributionTool;

/// What a step-driven contribution needs from its bundled package: the entry
/// point the editor calls and the one process permission its commands use.
#[derive(Clone, Debug)]
pub struct StepProvider {
    pub plugin_id: String,
    pub title: String,
    pub package: std::path::PathBuf,
    pub entry_point: String,
    pub activation_event: String,
    pub process: PluginProcessPermission,
}

/// Failures of the step protocol itself, or of a command a plugin ran.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum StepError {
    #[error("The {0} command-line tool was not found. Install it and make sure it is on PATH.")]
    ToolMissing(String),
    #[error("{}", command_failed_message(.command, .message))]
    CommandFailed { command: String, message: String },
    #[error("{0}")]
    ProtocolViolation(String),
    /// Swift propagated `CancellationError`; the blocking port carries it as a
    /// dedicated step failure with the same observable outcome.
    #[error("cancelled")]
    Cancelled,
}

fn command_failed_message(command: &str, message: &str) -> String {
    if message.is_empty() {
        format!("{command} failed.")
    } else {
        message.to_string()
    }
}

impl StepError {
    /// Swift's `LocalizedError.errorDescription`.
    pub fn error_description(&self) -> String {
        self.to_string()
    }
}

/// The runtime a step plugin resolves its execution binding through.
pub type StepRuntimeResolver = Arc<
    dyn Fn() -> Result<(PluginExecutionBinding, Arc<PluginHostProcessClient>), StepError>
        + Send
        + Sync,
>;

/// Process adapters share the application's manager and authorized host.
#[derive(Clone)]
pub struct StepPlugins {
    pub runtime: Arc<PluginRuntimeAccess>,
}

impl StepPlugins {
    pub fn new(runtime: Arc<PluginRuntimeAccess>) -> Self {
        StepPlugins { runtime }
    }

    pub fn plugin(
        &self,
        provider: &StepProvider,
        workspace: &Path,
    ) -> Result<StepPlugin, StepError> {
        let Some(tool) =
            ContributionTool::locate_with_process_environment(&provider.process.command)
        else {
            return Err(StepError::ToolMissing(provider.process.command.clone()));
        };
        let runtime = self.runtime.clone();
        let plugin_id = provider.plugin_id.clone();
        let activation_event = provider.activation_event.clone();
        Ok(StepPlugin {
            provider: provider.clone(),
            tool,
            workspace: workspace.to_path_buf(),
            runtime: Arc::new(move || {
                runtime
                    .resolve(&plugin_id, &activation_event)
                    .map_err(|error| StepError::ProtocolViolation(error.to_string()))
            }),
        })
    }
}

#[derive(Clone)]
pub struct StepPlugin {
    pub provider: StepProvider,
    pub tool: ContributionTool,
    pub workspace: std::path::PathBuf,
    pub(crate) runtime: StepRuntimeResolver,
}

impl StepPlugin {
    /// Calls the plugin's entry point with one step request and returns its raw
    /// JSON response.
    pub fn invoke(&self, request: &str, stdout: &str) -> Result<Vec<u8>, StepError> {
        let (binding, client) = (self.runtime)()?;
        let input = serde_json::json!({ "request": request, "stdout": stdout })
            .to_string()
            .into_bytes();
        let capability_id = format!("{}.{}", binding.plugin_id(), self.provider.entry_point);
        match client.prepare_capability(&binding, &capability_id, &input, None) {
            Ok(PluginPreparedCapabilityResult::Read(data)) => Ok(data),
            Ok(PluginPreparedCapabilityResult::HostCalls(_)) => Err(StepError::ProtocolViolation(
                "The plugin returned host calls.".to_string(),
            )),
            Err(error) => Err(StepError::ProtocolViolation(error.to_string())),
        }
    }
}

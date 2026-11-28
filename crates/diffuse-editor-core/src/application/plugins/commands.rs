//! `Editor/Sources/EditorCore/Application/Plugins/Commands.swift`.
//!
//! Calling a plugin entry point: one capability call with the entry point's
//! input, returning whatever the package answered.

use std::collections::BTreeMap;
use std::sync::Arc;

use diffuse_plugin::host::plugin_host_rpc::PluginPreparedCapabilityResult;

use crate::application::editor_application::EditorApplication;
use crate::application::plugins::ui_queue::UIEnqueue;
use crate::contributions::workbench::contributed::{WorkbenchCatalog, WorkbenchView};
use crate::contributions::workbench::surfaces::WorkbenchSession;

/// Failures of a plugin command or view.
#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginCommandError {
    #[error("The plugin that provides this is no longer enabled.")]
    Unavailable,
    #[error("The document is too large for plugin views.")]
    DocumentTooLarge,
}

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

impl EditorApplication {
    /// Captured inside the window's presentation boundary, then used by plugin
    /// pipes and timers.
    pub fn set_plugin_work_scheduler(&self, enqueue: Option<UIEnqueue>) {
        self.plugin_session.editor.workbench.ui_queue.install(enqueue);
    }

    /// Commands, panels and views of the enabled packages.
    pub fn workbench_catalog(&self) -> WorkbenchCatalog {
        self.plugin_session.editor.workbench.catalog()
    }

    /// The observable source of [`EditorApplication::workbench_catalog`].
    pub fn workbench(&self) -> &WorkbenchSession {
        &self.plugin_session.editor.workbench
    }

    /// The panel that holds the agent conversation, while a package declares
    /// that view *and* contributes an agent to hold it. Either half may come
    /// from any package; neither is a flag for one particular plugin.
    pub fn agent_panel_id(&self) -> Option<String> {
        if !self.is_agent_enabled() {
            return None;
        }
        self.workbench_catalog()
            .panel_for_view(&WorkbenchView::agent())
            .map(|panel| panel.id.clone())
    }

    /// Called whenever a package adds or removes a command or panel.
    pub fn set_workbench_change_handler(&self, handler: Option<Arc<dyn Fn() + Send + Sync>>) {
        self.plugin_session.editor.workbench.set_on_change(handler);
    }

    /// Shows a plugin's messages and failures; the shell installs it once.
    pub fn set_plugin_notification_handler(
        &self,
        handler: Option<Arc<dyn Fn(&str, bool) + Send + Sync>>,
    ) {
        self.plugin_session.editor.workbench.set_notify(handler);
    }

    /// Read-only workspace context shared by every plugin view in this window.
    pub fn set_plugin_workspace_catalog(&self, projects: BTreeMap<String, String>) {
        *self.plugin_session.editor.workspace_catalog.borrow_mut() = projects;
    }
}

//! `Editor/Sources/EditorCore/Application/Plugins/Reload.swift`.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::rc::Rc;

use diffuse_plugin::PluginError;
use diffuse_plugin::plugin_authorization::PluginAuthorizationError;

use crate::application::editor_application::EditorApplication;

use super::editor_plugin_capability_error::EditorPluginCapabilityError;
use super::plugins::PluginLifecycleError;

impl EditorApplication {
    /// Remounts only a package that still matches its stored authorization.
    pub fn reload_plugin(self: &Rc<Self>, id: &str) -> Result<(), PluginLifecycleError> {
        let operation = self.plugin_session.manager.reload(id);
        if matches!(
            operation,
            Err(PluginError::Authorization(
                PluginAuthorizationError::NoLongerValid
            ))
        ) {
            return Err(EditorPluginCapabilityError::PluginAuthorizationStale(id.into()).into());
        }
        let projection = self.synchronize_plugins();
        operation?;
        projection
    }

    pub(super) fn plugin_package_urls(&self) -> BTreeMap<String, PathBuf> {
        let enabled = self.plugin_session.manager.enabled_manifests();
        let mut packages = self.plugin_session.manager.package_urls();
        packages.retain(|id, _| enabled.contains_key(id));
        packages
    }
}

impl EditorApplication {
    pub fn start_watching_plugin_packages(&self, interval: std::time::Duration) {
        let mut state = self.plugin_session.state();
        if state.package_monitor.is_some() {
            return;
        }
        let changes = self.plugin_session.watched_changes.clone();
        let mut monitor = super::monitor::PluginPackageMonitor::new();
        monitor.set_packages(self.plugin_package_urls());
        monitor.start(interval, move |ids| {
            changes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .extend(ids);
            cove_runtime::scene::wake_scene_thread();
        });
        state.package_monitor = Some(monitor);
        drop(state);
        self.store
            .dispatch(crate::state::editor_reducer::EditorAction::console_message(
                "Watching enabled plugin packages for changes",
            ));
    }

    pub fn stop_watching_plugin_packages(&self) {
        let monitor = self.plugin_session.state().package_monitor.take();
        if let Some(monitor) = monitor {
            monitor.stop();
        }
        self.plugin_session
            .watched_changes
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clear();
    }

    pub fn poll_watched_plugin_packages(self: &Rc<Self>) {
        if self.plugin_session.is_updating() {
            return;
        }
        let ids = std::mem::take(
            &mut *self
                .plugin_session
                .watched_changes
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner),
        );
        let packages = self.plugin_package_urls();
        for id in ids {
            let Some(package) = packages.get(&id) else {
                continue;
            };
            if self
                .plugin_session
                .state()
                .pending_approval
                .as_ref()
                .is_some_and(|pending| pending.inspection.manifest.id == id)
            {
                continue;
            }
            match self.reload_plugin(&id) {
                Ok(()) => self.log_console(
                    "Reloaded changed plugin",
                    crate::state::editor_state::EditorConsoleSeverity::Info,
                    Some(id),
                    None,
                    None,
                ),
                Err(error)
                    if error
                        .downcast_ref::<EditorPluginCapabilityError>()
                        .is_some_and(|error| {
                            matches!(
                                error,
                                EditorPluginCapabilityError::PluginAuthorizationStale(_)
                            )
                        }) =>
                {
                    self.log_warning("Plugin changed on disk; authorization required", id);
                    self.inspect_plugin_for_management(package);
                }
                Err(error) => self.log_warning("Plugin reload failed", format!("{id}: {error}")),
            }
        }
    }

    pub fn reload_plugin_from_management(self: &Rc<Self>, id: &str) {
        use crate::ai::plugins::editor_plugin_management_state::EditorPluginManagementPhase;

        let candidate = self.store.plugin_management().candidate;
        match self.reload_plugin(id) {
            Ok(()) => self.publish_plugin_management(
                EditorPluginManagementPhase::Idle,
                candidate,
                Some(format!("Reloaded plugin '{id}'.")),
            ),
            Err(error) => {
                if error
                    .downcast_ref::<EditorPluginCapabilityError>()
                    .is_some_and(|error| {
                        matches!(
                            error,
                            EditorPluginCapabilityError::PluginAuthorizationStale(_)
                        )
                    })
                    && let Some(package) = self.plugin_package_urls().get(id)
                {
                    self.inspect_plugin_for_management(package);
                } else {
                    self.publish_plugin_management(
                        EditorPluginManagementPhase::Failed,
                        candidate,
                        Some(error.to_string()),
                    );
                }
            }
        }
    }
}

//! `Editor/Sources/EditorCore/Contributions/RuntimeAccess.swift`.

use std::sync::{Arc, Mutex};

use diffuse_plugin::PluginError;
use diffuse_plugin::host::plugin_host_process_client::PluginHostProcessClient;
use diffuse_plugin::lifecycle::status::PluginManagerError;
use diffuse_plugin::plugin_authorization::PluginExecutionBinding;

use crate::application::plugins::contributions::PluginContributions;
use crate::tasks::catalog::TaskProvider;
use crate::version_control::providers::VersionControlProvider;

/// Adapters request a live binding; they never inspect, authorize or own mounts.
pub type RuntimeResolver = Arc<
    dyn Fn(
            &str,
            &str,
        ) -> Result<(PluginExecutionBinding, Arc<PluginHostProcessClient>), PluginError>
        + Send
        + Sync,
>;

pub struct PluginRuntimeAccess {
    resolver: Mutex<Option<RuntimeResolver>>,
    pub contributions: Arc<PluginContributions>,
}

impl PluginRuntimeAccess {
    pub fn new(contributions: Arc<PluginContributions>) -> Self {
        PluginRuntimeAccess {
            resolver: Mutex::new(None),
            contributions,
        }
    }

    fn package_snapshot(
        &self,
    ) -> Vec<diffuse_plugin::contract::plugin_package::ValidatedPluginPackage> {
        self.contributions
            .tasks
            .snapshot()
            .values
            .into_iter()
            .map(|value| value.value)
            .collect()
    }

    pub fn task_providers(&self) -> Vec<TaskProvider> {
        TaskProvider::registered(&self.package_snapshot())
    }

    pub fn version_control_providers(&self) -> Vec<VersionControlProvider> {
        let packages: Vec<diffuse_plugin::contract::plugin_package::ValidatedPluginPackage> = self
            .contributions
            .version_control
            .snapshot()
            .values
            .into_iter()
            .map(|value| value.value)
            .collect();
        VersionControlProvider::registered(&packages)
    }

    pub fn configure(&self, resolver: RuntimeResolver) {
        *self
            .resolver
            .lock()
            .unwrap_or_else(|error| error.into_inner()) = Some(resolver);
    }

    pub fn resolve(
        &self,
        id: &str,
        event: &str,
    ) -> Result<(PluginExecutionBinding, Arc<PluginHostProcessClient>), PluginError> {
        let resolver = self
            .resolver
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .clone();
        let Some(resolver) = resolver else {
            return Err(PluginManagerError::RuntimeUnavailable.into());
        };
        resolver(id, event)
    }
}

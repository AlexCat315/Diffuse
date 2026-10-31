//! Plugin phases, manager errors and the runtime driver seam.
//!
//! Ported from `Engine/Sources/PluginRuntime/Lifecycle/Status.swift`.

use std::fmt;
use std::path::PathBuf;

use diffuse_capability::support::disposal::Registration;
use serde::{Deserialize, Serialize};

use crate::PluginError;
use crate::plugin_authorization::{
    PluginAuthorizationRecord, PluginExecutionBinding, PluginInspection,
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PluginPhase {
    Installed,
    Enabled,
    Activated,
    Failed,
}

#[derive(Clone, Debug, PartialEq)]
pub struct PluginStatus {
    pub inspection: PluginInspection,
    pub phase: PluginPhase,
    pub is_enabled: bool,
    pub failure: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum PluginManagerError {
    #[error("Plugin '{0}' is already enabled.")]
    AlreadyEnabled(String),
    #[error("Plugin '{0}' is not installed.")]
    NotInstalled(String),
    #[error("Plugin '{0}' is not enabled.")]
    NotEnabled(String),
    #[error("The plugin runtime is unavailable.")]
    RuntimeUnavailable,
    #[error("The plugin manager has stopped.")]
    Stopped,
    #[error("Plugin activation cycle at '{0}'.")]
    ActivationCycle(String),
}

/// Swift's `PluginRuntimeActivation` refused to define a case for a
/// mis-signature; the runtime driver's failures are the same families
/// `PluginManager::activate` propagated, so one enum carries them.
#[derive(Debug, thiserror::Error)]
pub enum PluginRuntimeError {
    #[error(transparent)]
    Manager(#[from] PluginManagerError),
    #[error(transparent)]
    Authorization(#[from] crate::plugin_authorization::PluginAuthorizationError),
    #[error(transparent)]
    Package(#[from] crate::contract::plugin_package::PluginPackageError),
    #[error(transparent)]
    Other(#[from] Box<PluginError>),
}

#[derive(Clone)]
pub struct PluginRuntimeActivation {
    pub binding: PluginExecutionBinding,
    pub registration: Option<std::sync::Arc<Registration>>,
}

impl PluginRuntimeActivation {
    pub fn new(
        binding: PluginExecutionBinding,
        registration: Option<std::sync::Arc<Registration>>,
    ) -> Self {
        PluginRuntimeActivation {
            binding,
            registration,
        }
    }
}

/// The seam through which the plugin manager starts and stops real runtimes.
/// Swift's `@Sendable async` closures become boxed `Fn` values the manager calls
/// on its own worker thread (MIGRATION.md §5.5).
type ActivateFn = Box<
    dyn Fn(PathBuf, PluginAuthorizationRecord) -> Result<PluginRuntimeActivation, PluginError>
        + Send
        + Sync,
>;
type DeactivateFn = Box<dyn Fn(&PluginExecutionBinding) -> Result<(), PluginError> + Send + Sync>;

pub struct PluginRuntimeDriver {
    pub activate: ActivateFn,
    pub deactivate: DeactivateFn,
    pub stop: Box<dyn Fn() + Send + Sync>,
}

impl PluginRuntimeDriver {
    pub fn new(
        activate: impl Fn(
            PathBuf,
            PluginAuthorizationRecord,
        ) -> Result<PluginRuntimeActivation, PluginError>
        + Send
        + Sync
        + 'static,
        deactivate: impl Fn(&PluginExecutionBinding) -> Result<(), PluginError> + Send + Sync + 'static,
        stop: impl Fn() + Send + Sync + 'static,
    ) -> Self {
        PluginRuntimeDriver {
            activate: Box::new(activate),
            deactivate: Box::new(deactivate),
            stop: Box::new(stop),
        }
    }
}

impl fmt::Debug for PluginRuntimeDriver {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("PluginRuntimeDriver")
    }
}

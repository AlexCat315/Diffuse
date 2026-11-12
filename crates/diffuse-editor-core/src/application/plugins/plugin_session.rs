//! `Editor/Sources/EditorCore/Application/Plugins/PluginSession.swift`.
//!
//! The lifecycle owner, host infrastructure and domain snapshots of one editor.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread::JoinHandle;

use diffuse_capability::capability_contract::PluginCapabilityAuthority;
use diffuse_capability::capability_registry::CapabilityRegistry;
use diffuse_plugin::contract::plugin_package::PluginPackageLoader;
use diffuse_plugin::contribution::registry::ContributionPointRegistry;
use diffuse_plugin::lifecycle::manager::PluginManager;
use diffuse_plugin::plugin_authorization::PluginInspection;

use super::contributions::PluginContributions;
use super::editor_integration::PluginEditorIntegration;
use super::host_pool::PluginHostPool;
use super::monitor::PluginPackageMonitor;
use super::plugin_components::PluginComponentStore;
use crate::ai::plugins::editor_plugin_authorization_store::EditorPluginAuthorizationStore;
use crate::contributions::agents::AgentCatalog;
use crate::contributions::ai_providers::{AIProviderCatalog, AIProviderDescriptor};
use crate::contributions::languages::LanguageCatalog;
use crate::contributions::runtime_access::PluginRuntimeAccess;

pub struct PendingPluginApproval {
    pub package_url: PathBuf,
    pub inspection: PluginInspection,
}

#[derive(Debug, thiserror::Error)]
pub enum PluginSessionError {
    #[error(transparent)]
    Manifest(#[from] diffuse_plugin::contract::plugin_manifest::PluginManifestValidationError),
    #[error("the plugin host executable is unavailable")]
    HostUnavailable,
}

/// Mutable session snapshots. Every field is main-thread state; the mutex only
/// makes `EditorApplication`'s `@unchecked Sendable` contract explicit.
pub struct PluginSessionState {
    pub pending_approval: Option<PendingPluginApproval>,
    pub theme_revision: Option<u64>,
    pub provider_revision: Option<u64>,
    pub language_revision: Option<u64>,
    pub agent_revision: Option<u64>,
    pub ai_authorities: BTreeMap<String, PluginCapabilityAuthority>,
    pub languages: LanguageCatalog,
    pub providers: AIProviderCatalog,
    pub agents: AgentCatalog,
    pub ai_provider: Option<AIProviderDescriptor>,
    pub package_monitor: Option<PluginPackageMonitor>,
    pub bundled_startup: Option<JoinHandle<()>>,
    pub projection: Option<JoinHandle<Result<(), String>>>,
}

impl Default for PluginSessionState {
    fn default() -> Self {
        PluginSessionState {
            pending_approval: None,
            theme_revision: None,
            provider_revision: None,
            language_revision: None,
            agent_revision: None,
            ai_authorities: BTreeMap::new(),
            languages: LanguageCatalog::with_default_packages(),
            providers: AIProviderCatalog::bundled(),
            agents: AgentCatalog::empty(),
            ai_provider: None,
            package_monitor: None,
            bundled_startup: None,
            projection: None,
        }
    }
}

pub struct PluginSession {
    /// One host process per plugin: a fault in one plugin cannot stall or kill
    /// another. The pool is filled on first use.
    pub hosts: PluginHostPool,
    pub manager: PluginManager,
    pub contributions: Arc<PluginContributions>,
    pub editor: PluginEditorIntegration,
    pub runtime: PluginRuntimeAccess,
    pub authorization_store: EditorPluginAuthorizationStore,
    pub components: PluginComponentStore,
    state: Mutex<PluginSessionState>,
    shutdown: Arc<AtomicBool>,
}

impl PluginSession {
    pub fn new(
        project_directory: &str,
        host_executable: impl Fn() -> Result<PathBuf, diffuse_plugin::PluginError>
        + Send
        + Sync
        + 'static,
        on_host_crash: impl Fn(&str) + Send + Sync + 'static,
    ) -> Result<Self, PluginSessionError> {
        let authorization_store = EditorPluginAuthorizationStore::new(project_directory);
        let hosts = PluginHostPool::new(host_executable, on_host_crash);
        let contributions = Arc::new(PluginContributions::new());
        let registry = CapabilityRegistry::default_registry();
        let loader = PluginPackageLoader::new(
            registry.clone(),
            None,
            ContributionPointRegistry::standard(),
        );
        let host_capabilities = registry
            .all_verbs()
            .into_iter()
            .filter_map(|verb| {
                registry
                    .descriptor(&verb)
                    .map(|descriptor| (verb, descriptor.version))
            })
            .collect::<BTreeMap<_, _>>();
        let manager = PluginManager::new(contributions.registrar()?, loader, host_capabilities);
        let runtime = PluginRuntimeAccess::new(contributions.clone());
        Ok(PluginSession {
            hosts,
            manager,
            contributions,
            editor: PluginEditorIntegration::new(),
            runtime,
            authorization_store,
            components: PluginComponentStore::new(),
            state: Mutex::new(PluginSessionState::default()),
            shutdown: Arc::new(AtomicBool::new(false)),
        })
    }

    pub fn is_updating(&self) -> bool {
        self.manager.is_busy()
    }

    pub fn state(&self) -> MutexGuard<'_, PluginSessionState> {
        self.state
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Cancellation flag handed to the bundled-startup and projection workers.
    pub fn shutdown_flag(&self) -> Arc<AtomicBool> {
        self.shutdown.clone()
    }

    pub fn stop(&self) {
        self.shutdown.store(true, Ordering::Release);
        self.editor.stop();
        let mut state = self.state();
        if let Some(startup) = state.bundled_startup.take() {
            drop(startup);
        }
        if let Some(projection) = state.projection.take() {
            drop(projection);
        }
        if let Some(monitor) = state.package_monitor.take() {
            monitor.stop();
        }
        state.pending_approval = None;
        drop(state);
        self.manager.stop();
        self.hosts.stop_all();
    }
}

impl Drop for PluginSession {
    fn drop(&mut self) {
        self.shutdown.store(true, Ordering::Release);
    }
}

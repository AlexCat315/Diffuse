//! Translation of `Editor/Sources/EditorCore/Application/Plugins/HostPool.swift`.
//!
//! One isolated host process per plugin.
//!
//! A plugin is third-party-shaped code whether or not it ships with the editor:
//! it can loop, exhaust memory or crash. Sharing one host process couples them,
//! so a fault in any plugin stalls or kills every other. Each plugin therefore
//! gets its own process, created on first use and dropped when it exits.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use diffuse_plugin::PluginError;
use diffuse_plugin::host::plugin_host_process_client::{
    PluginHostClientError, PluginHostProcessClient,
};
use diffuse_plugin::host::plugin_host_rpc::{
    PluginCapabilityInvoking, PluginHostServiceCall, PluginPreparedCapabilityResult,
    PluginQuerySnapshot,
};
use diffuse_plugin::plugin_authorization::PluginExecutionBinding;

type HostCallHandler =
    Arc<dyn Fn(&str, &PluginHostServiceCall) -> Result<Vec<u8>, PluginError> + Send + Sync>;
type ExecutableResolver = Box<dyn Fn() -> Result<PathBuf, PluginError> + Send + Sync>;

/// One client per plugin, keyed by the plugin id.
pub struct PluginHostPool {
    clients: Mutex<BTreeMap<String, Arc<PluginHostProcessClient>>>,
    executable: ExecutableResolver,
    on_crash: Arc<dyn Fn(&str) + Send + Sync>,
    host_call_handler: Arc<Mutex<Option<HostCallHandler>>>,
}

impl PluginHostPool {
    /// `executable` resolves lazily so a project with no plugins never launches
    /// a process.
    pub fn new(
        executable: impl Fn() -> Result<PathBuf, PluginError> + Send + Sync + 'static,
        on_crash: impl Fn(&str) + Send + Sync + 'static,
    ) -> Self {
        PluginHostPool {
            clients: Mutex::new(BTreeMap::new()),
            executable: Box::new(executable),
            on_crash: Arc::new(on_crash),
            host_call_handler: Arc::new(Mutex::new(None)),
        }
    }

    fn lock(&self) -> MutexGuard<'_, BTreeMap<String, Arc<PluginHostProcessClient>>> {
        self.clients
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    pub fn host_call_handler(&self) -> Option<HostCallHandler> {
        self.host_call_handler
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    pub fn set_host_call_handler(&self, handler: Option<HostCallHandler>) {
        *self
            .host_call_handler
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = handler;
    }

    /// The process serving this plugin. A plugin never shares one.
    pub fn client(&self, plugin_id: &str) -> Result<Arc<PluginHostProcessClient>, PluginError> {
        let mut clients = self.lock();
        if let Some(existing) = clients.get(plugin_id) {
            return Ok(existing.clone());
        }
        let executable = (self.executable)()?;
        let notify_id = plugin_id.to_string();
        let notify = self.on_crash.clone();
        let handler = self.host_call_handler.clone();
        let client = Arc::new(PluginHostProcessClient::new(
            executable,
            Vec::new(),
            Some(Box::new(move |_generation| notify(&notify_id))),
        ));
        let call_id = plugin_id.to_string();
        let mut client = client;
        {
            let client = Arc::get_mut(&mut client).expect("client was just created");
            client.on_host_call = Some(Box::new(move |call: &PluginHostServiceCall| {
                let handler = handler
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                let Some(handler) = handler.as_ref() else {
                    return Err(PluginHostClientError::CommunicationFailed.into());
                };
                handler(&call_id, call)
            }));
        }
        let inserted = clients
            .get(plugin_id)
            .cloned()
            .expect("client was just inserted");
        Ok(inserted)
    }

    pub fn existing(&self, plugin_id: &str) -> Option<Arc<PluginHostProcessClient>> {
        self.lock().get(plugin_id).cloned()
    }

    /// Removes and stops one plugin's process. Other plugins keep running.
    pub fn discard(&self, plugin_id: &str) -> Option<Arc<PluginHostProcessClient>> {
        let client = self.lock().remove(plugin_id);
        if let Some(client) = client.as_ref() {
            client.stop();
        }
        client
    }

    pub fn stop_all(&self) {
        let all: Vec<Arc<PluginHostProcessClient>> = {
            let mut clients = self.lock();
            let values: Vec<Arc<PluginHostProcessClient>> = clients.values().cloned().collect();
            clients.clear();
            values
        };
        for client in all {
            client.stop();
        }
    }

    pub fn plugin_ids(&self) -> Vec<String> {
        self.lock().keys().cloned().collect()
    }
}

/// Routes each capability call to the process that owns the plugin, so a
/// restart or crash invalidates only that plugin.
pub struct PluginHostRouter {
    pool: Arc<PluginHostPool>,
}

impl PluginHostRouter {
    pub fn new(pool: Arc<PluginHostPool>) -> Self {
        PluginHostRouter { pool }
    }
}

impl PluginCapabilityInvoking for PluginHostRouter {
    fn generation(&self) -> u64 {
        // There is no single host generation once processes are per plugin.
        // Every check goes through `validate`.
        0
    }

    fn validate(&self, binding: &PluginExecutionBinding) -> bool {
        // Validation must not start a process: a binding is only meaningful
        // while the process that accepted it is alive.
        self.pool
            .existing(binding.plugin_id())
            .is_some_and(|client| binding.host_generation == client.generation())
    }

    fn prepare_capability(
        &self,
        binding: &PluginExecutionBinding,
        capability_id: &str,
        input: &[u8],
        query_snapshot: Option<&PluginQuerySnapshot>,
    ) -> Result<PluginPreparedCapabilityResult, PluginError> {
        let client = self.pool.client(binding.plugin_id())?;
        client.prepare_capability(binding, capability_id, input, query_snapshot)
    }
}

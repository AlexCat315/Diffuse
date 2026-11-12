//! Translation of
//! `Editor/Sources/EditorCore/Contributions/Workbench/Surfaces.swift`.

use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use diffuse_plugin::PluginError;
use diffuse_plugin::contract::plugin_json::PluginJSON;
use diffuse_plugin::contract::plugin_package::ValidatedPluginPackage;
use diffuse_plugin::contribution::catalog::ContributionSnapshot;
use diffuse_plugin::contribution::workbench::view::{PluginViewResult, UIEffect, UIEvent};

use crate::application::plugins::ui_queue::PluginUIQueue;
use crate::contributions::workbench::contributed::WorkbenchCatalog;
use crate::contributions::workbench::view_session::{PluginContentSource, PluginViewSession};

pub type PluginViewInvoke = Arc<
    dyn Fn(Option<&PluginJSON>, Option<&UIEvent>) -> Result<PluginViewResult, PluginError>
        + Send
        + Sync,
>;

/// The workbench domain of one editor session: its catalog, the content
/// packages describe for it and the shell to tell when it changes. Views
/// observe the catalog through `register_observer` to follow packages as they
/// come and go.
pub struct WorkbenchSession {
    pub ui_queue: Arc<PluginUIQueue>,
    catalog: Mutex<WorkbenchCatalog>,
    revisions: Mutex<Vec<u64>>,
    sessions: Mutex<BTreeMap<String, Arc<PluginViewSession>>>,
    on_change: Mutex<Option<Arc<dyn Fn() + Send + Sync>>>,
    notify: Mutex<Option<Arc<dyn Fn(&str, bool) + Send + Sync>>>,
    observers: Mutex<BTreeMap<u64, Arc<dyn Fn() + Send + Sync>>>,
    next_observer: AtomicU64,
}

impl WorkbenchSession {
    pub fn new() -> Self {
        WorkbenchSession {
            ui_queue: Arc::new(PluginUIQueue::new()),
            catalog: Mutex::new(WorkbenchCatalog::empty()),
            revisions: Mutex::new(Vec::new()),
            sessions: Mutex::new(BTreeMap::new()),
            on_change: Mutex::new(None),
            notify: Mutex::new(None),
            observers: Mutex::new(BTreeMap::new()),
            next_observer: AtomicU64::new(0),
        }
    }

    pub fn catalog(&self) -> WorkbenchCatalog {
        self.catalog
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    pub fn set_on_change(&self, handler: Option<Arc<dyn Fn() + Send + Sync>>) {
        *self
            .on_change
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = handler;
    }

    /// Shows a plugin's message; `true` marks a failure. Installed by the shell.
    pub fn set_notify(&self, handler: Option<Arc<dyn Fn(&str, bool) + Send + Sync>>) {
        *self
            .notify
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = handler;
    }

    /// Publishes a new catalog when the registrations behind it changed.
    pub fn update(&self, snapshots: &[ContributionSnapshot<ValidatedPluginPackage>]) {
        let next: Vec<u64> = snapshots.iter().map(|snapshot| snapshot.revision).collect();
        {
            let revisions = self
                .revisions
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if *revisions == next {
                return;
            }
        }
        let mut packages: BTreeMap<String, ValidatedPluginPackage> = BTreeMap::new();
        for value in snapshots.iter().flat_map(|snapshot| snapshot.values.iter()) {
            packages.insert(value.plugin_id.clone(), value.value.clone());
        }
        *self
            .revisions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = next;
        self.replace(WorkbenchCatalog::from_packages(
            &packages.values().cloned().collect::<Vec<_>>(),
        ));
    }

    /// Content loaded for a panel or view that left or changed is dropped with it.
    pub fn replace(&self, catalog: WorkbenchCatalog) {
        {
            let mut current = self
                .catalog
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if *current == catalog {
                return;
            }
            *current = catalog.clone();
        }
        let stale: Vec<Arc<PluginViewSession>> = {
            let mut sessions = self
                .sessions
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let stale_keys: Vec<String> = sessions
                .iter()
                .filter(|(_, session)| !session.source().is_current(&catalog))
                .map(|(key, _)| key.clone())
                .collect();
            stale_keys
                .into_iter()
                .filter_map(|key| sessions.remove(&key))
                .collect()
        };
        for session in stale {
            session.cancel();
        }
        self.send_notification();
        let handler = self
            .on_change
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        if let Some(handler) = handler {
            handler();
        }
    }

    /// The session for a view, created and first rendered on demand.
    pub fn session(
        &self,
        source: PluginContentSource,
        invoke: PluginViewInvoke,
        effects: Arc<dyn Fn(Vec<UIEffect>) + Send + Sync>,
    ) -> Arc<PluginViewSession> {
        let key = source.key();
        let mut sessions = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if let Some(existing) = sessions.get(&key)
            && *existing.source() == source
        {
            return existing.clone();
        }
        let session = Arc::new(PluginViewSession::new(
            source,
            invoke,
            self.ui_queue.clone(),
        ));
        session.set_effect_handler(Some(effects));
        sessions.insert(key, session.clone());
        drop(sessions);
        session.render();
        session
    }

    /// A command may change what the package's views show.
    pub fn render_views(&self, plugin_id: &str) {
        let sessions: Vec<Arc<PluginViewSession>> = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .filter(|session| session.source().plugin_id() == plugin_id)
            .cloned()
            .collect();
        for session in sessions {
            session.render();
        }
    }

    pub fn stop(&self) {
        let sessions: Vec<Arc<PluginViewSession>> = {
            let mut sessions = self
                .sessions
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let values = sessions.values().cloned().collect();
            sessions.clear();
            values
        };
        for session in sessions {
            session.cancel();
        }
    }

    pub fn register_observer(&self, handler: Arc<dyn Fn() + Send + Sync>) -> u64 {
        let token = self.next_observer.fetch_add(1, Ordering::SeqCst);
        self.observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(token, handler);
        token
    }

    pub fn unregister_observer(&self, token: u64) {
        self.observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&token);
    }

    fn send_notification(&self) {
        let handlers: Vec<Arc<dyn Fn() + Send + Sync>> = self
            .observers
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .values()
            .cloned()
            .collect();
        for handler in handlers {
            handler();
        }
    }
}

impl Default for WorkbenchSession {
    fn default() -> Self {
        Self::new()
    }
}

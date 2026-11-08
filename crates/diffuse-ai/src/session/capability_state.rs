//! Ported from `Engine/Sources/AIRuntime/Session/CapabilityState.swift`.

use std::sync::Arc;

use diffuse_capability::capability_contract::CapabilityExposureSnapshot;
use diffuse_capability::capability_registry::CapabilityRegistry;

use crate::planning::capability_draft_pipeline::{CapabilityDraftStore, CapabilityInvocationDraft};
use crate::tools::plugin_capability_executor::{
    PluginCapabilityExecutor, PluginQuerySnapshotProvider,
};

/// Transient authority and drafts belong together and never enter chat history.
pub struct SessionCapabilityState {
    host_registry: CapabilityRegistry,
    pub registry: CapabilityRegistry,
    pub drafts: Arc<CapabilityDraftStore>,
    pub executor: Option<PluginCapabilityExecutor>,
    pub query_snapshot_provider: Option<PluginQuerySnapshotProvider>,
    pub generation: u64,
    pub submitted_snapshot: Option<CapabilityExposureSnapshot>,
    pub submitted_drafts: Vec<CapabilityInvocationDraft>,
}

impl SessionCapabilityState {
    pub fn new(
        host_registry: CapabilityRegistry,
        executor: Option<PluginCapabilityExecutor>,
        query_snapshot_provider: Option<PluginQuerySnapshotProvider>,
    ) -> Self {
        let registry = match &executor {
            Some(executor) => executor.registry.clone(),
            None => host_registry.clone(),
        };
        Self {
            host_registry,
            drafts: Arc::new(CapabilityDraftStore::new(registry.clone())),
            registry,
            executor,
            query_snapshot_provider,
            generation: 0,
            submitted_snapshot: None,
            submitted_drafts: Vec::new(),
        }
    }

    pub fn replace(
        &mut self,
        executor: Option<PluginCapabilityExecutor>,
        query_snapshot_provider: Option<PluginQuerySnapshotProvider>,
    ) {
        self.executor = executor;
        self.query_snapshot_provider = query_snapshot_provider;
        self.registry = match &self.executor {
            Some(executor) => executor.registry.clone(),
            None => self.host_registry.clone(),
        };
        self.drafts = Arc::new(CapabilityDraftStore::new(self.registry.clone()));
        self.generation = self.generation.wrapping_add(1);
        self.submitted_snapshot = None;
        self.submitted_drafts = Vec::new();
    }
}

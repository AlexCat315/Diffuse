//! `PerceptionWorkerFactory.swift` — manifest-driven worker construction.

use std::collections::BTreeMap;
use std::sync::Arc;

use crate::core::manifest_scanner::{ManifestScanner, ScanResult};
use crate::core::perception_contracts::PerceptionModelManifest;
use crate::core::perception_service::PerceptionService;
use crate::worker::perception_worker::PerceptionWorker;

/// Builder closure registered per backend family.
pub type Builder =
    Box<dyn Fn(&PerceptionModelManifest) -> Option<Arc<dyn PerceptionWorker>> + Send + Sync>;

/// Creates `PerceptionWorker` instances from manifests by matching
/// `manifest.backendFamily` against registered builders.
pub struct PerceptionWorkerFactory {
    builders: BTreeMap<String, Builder>,
}

impl PerceptionWorkerFactory {
    pub fn new() -> Self {
        PerceptionWorkerFactory {
            builders: BTreeMap::new(),
        }
    }

    pub fn register<F>(&mut self, backend_family: impl Into<String>, builder: F)
    where
        F: Fn(&PerceptionModelManifest) -> Option<Arc<dyn PerceptionWorker>>
            + Send
            + Sync
            + 'static,
    {
        self.builders
            .insert(backend_family.into(), Box::new(builder));
    }

    /// Returns a worker for `manifest.backend_family`, or `None` when no builder
    /// is registered. Callers check `LicenseGate` separately.
    pub fn make_worker(
        &self,
        manifest: &PerceptionModelManifest,
    ) -> Option<Arc<dyn PerceptionWorker>> {
        self.builders
            .get(&manifest.backend_family)
            .and_then(|builder| builder(manifest))
    }
}

impl Default for PerceptionWorkerFactory {
    fn default() -> Self {
        Self::new()
    }
}

impl PerceptionService {
    /// Scans `directory` for manifests, builds workers through `factory` and
    /// registers them. Returns the scan result so callers can surface errors.
    pub fn discover_and_register(
        &self,
        directory: &std::path::Path,
        factory: &PerceptionWorkerFactory,
    ) -> ScanResult {
        let scan = ManifestScanner::scan(directory);
        for manifest in &scan.manifests {
            if let Some(worker) = factory.make_worker(manifest) {
                self.register(worker);
            }
        }
        scan
    }
}

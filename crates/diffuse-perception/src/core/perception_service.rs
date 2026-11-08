//! `PerceptionService.swift` — worker registration, task selection and tagging.
//!
//! Swift's `actor` becomes a `Mutex`-guarded worker list (MIGRATION.md §5.5).

use std::path::Path;
use std::sync::{Arc, Mutex};

use diffuse_intent::transactions::world_event::WorldEvent;
use diffuse_kernel::codable::new_uuid;

use crate::core::perception_contracts::PerceptionTask;
use crate::gates::license_gate::{LicenseGate, LicenseGateDecision, PerceptionDistributionMode};
use crate::support::perception_world_event_mapper::PerceptionWorldEventMapper;
use crate::worker::perception_worker::{PerceptionRuntimeError, PerceptionWorker};

/// High-level orchestrator that registers workers, selects one for a task and
/// maps results to `WorldEvent`s ready for an AI world context.
pub struct PerceptionService {
    workers: Mutex<Vec<Arc<dyn PerceptionWorker>>>,
    license_gate: LicenseGate,
    distribution_mode: PerceptionDistributionMode,
    mapper: PerceptionWorldEventMapper,
}

impl PerceptionService {
    pub fn new() -> Self {
        Self::with_options(
            LicenseGate::default(),
            PerceptionDistributionMode::LocalDev,
            PerceptionWorldEventMapper::new(),
        )
    }

    pub fn with_options(
        license_gate: LicenseGate,
        distribution_mode: PerceptionDistributionMode,
        mapper: PerceptionWorldEventMapper,
    ) -> Self {
        PerceptionService {
            workers: Mutex::new(Vec::new()),
            license_gate,
            distribution_mode,
            mapper,
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Vec<Arc<dyn PerceptionWorker>>> {
        self.workers
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn register(&self, worker: Arc<dyn PerceptionWorker>) {
        self.lock().push(worker);
    }

    /// Returns the first registered worker for `task` that passes the license gate.
    pub fn available_worker(&self, task: PerceptionTask) -> Option<Arc<dyn PerceptionWorker>> {
        self.lock()
            .iter()
            .find(|worker| {
                let manifest = worker.manifest();
                if manifest.task != task {
                    return false;
                }
                let decision = self
                    .license_gate
                    .evaluate(&manifest, self.distribution_mode);
                decision == LicenseGateDecision::Allowed
                    || decision == LicenseGateDecision::AllowedWithAttribution
            })
            .cloned()
    }

    /// Runs perception on `image_url` and returns `[WorldEvent]` encoding inferred
    /// properties on `entity_ref`.
    pub fn tag(
        &self,
        entity_ref: &str,
        image_url: &Path,
        task: PerceptionTask,
        max_results: i64,
    ) -> Result<Vec<WorldEvent>, PerceptionRuntimeError> {
        let Some(worker) = self.available_worker(task) else {
            return Err(PerceptionRuntimeError::WorkerUnavailable(format!(
                "no registered worker for task '{}'",
                task.as_str()
            )));
        };
        let result = worker.analyze_image_async(image_url, &new_uuid(), max_results)?;
        Ok(self.mapper.make_world_events(&result, entity_ref))
    }

    /// Swift's `tag(entityRef:imageURL:)` default: classification, 5 results.
    pub fn tag_default(
        &self,
        entity_ref: &str,
        image_url: &Path,
    ) -> Result<Vec<WorldEvent>, PerceptionRuntimeError> {
        self.tag(entity_ref, image_url, PerceptionTask::Classification, 5)
    }
}

impl Default for PerceptionService {
    fn default() -> Self {
        Self::new()
    }
}

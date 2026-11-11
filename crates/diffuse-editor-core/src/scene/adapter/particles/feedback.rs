//! `Editor/Sources/EditorCore/Scene/Adapter/Particles/Feedback.swift`.
//!
//! Buffers render-thread readbacks for one scene generation. Replacing or
//! restoring the authored scene invalidates both queued and in-flight feedback.

use std::sync::{Arc, Mutex, Weak};

use diffuse_render::core::render_stats::GPUParticleSimulationEventSnapshot;
use diffuse_scene::particles::particle_simulation_event_apply_report::ParticleSimulationEventApplyReport;

#[derive(Default)]
struct InboxState {
    pending: Vec<GPUParticleSimulationEventSnapshot>,
    generation: u64,
    last_report: Option<ParticleSimulationEventApplyReport>,
}

/// Swift's `@unchecked Sendable` class; the shared `Mutex` makes the inbox
/// usable across the render thread.
#[derive(Clone, Default)]
pub struct ParticleFeedbackInbox {
    state: Arc<Mutex<InboxState>>,
}

impl ParticleFeedbackInbox {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn report(&self) -> ParticleSimulationEventApplyReport {
        self.state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .last_report
            .clone()
            .unwrap_or_else(ParticleSimulationEventApplyReport::empty)
    }

    /// Swift's `@Sendable ([GPUParticleSimulationEventSnapshot]) -> Void`.
    pub fn make_handler(&self) -> Arc<dyn Fn(&[GPUParticleSimulationEventSnapshot]) + Send + Sync> {
        let current_generation = self
            .state
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .generation;
        let weak: Weak<Mutex<InboxState>> = Arc::downgrade(&self.state);
        Arc::new(move |snapshots: &[GPUParticleSimulationEventSnapshot]| {
            if snapshots.is_empty() {
                return;
            }
            let Some(state) = weak.upgrade() else {
                return;
            };
            let mut state = state.lock().unwrap_or_else(|error| error.into_inner());
            if state.generation == current_generation {
                state.pending.extend_from_slice(snapshots);
            }
        })
    }

    pub fn drain(&self) -> Vec<GPUParticleSimulationEventSnapshot> {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        std::mem::take(&mut state.pending)
    }

    pub fn record(&self, report: ParticleSimulationEventApplyReport) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        state.last_report = Some(report);
    }

    pub fn invalidate(&self) {
        let mut state = self.state.lock().unwrap_or_else(|error| error.into_inner());
        state.generation = state.generation.wrapping_add(1);
        state.pending.clear();
        state.last_report = None;
    }
}

//! `Editor/Sources/EditorCore/Application/Diagnostics/Diagnostics.swift`.
//!
//! The read-only frame/particle/GPU views the developer tools and the agent's
//! diagnostics tools sample, plus the averaging window that turns per-frame
//! timings into `EditorFrameStats`.

use diffuse_render::core::render_stats::RenderFrameStats;
use diffuse_render::surface::viewport_surface::ViewportSurfaceState;
use diffuse_scene::particles::particle_scalability::ParticleScalabilityStateResource;
use diffuse_scene::particles::particle_simulation_event_apply_report::ParticleSimulationEventApplyReport;
use diffuse_scene::particles::particle_stats::ParticleFrameStatsResource;
use diffuse_scene::rendering::render_scene::RenderScene;

use crate::application::editor_application::EditorApplication;
use crate::state::editor_reducer::EditorAction;
use crate::state::editor_state::{EditorFrameStats, EditorParticleDiagnosticsSample};

impl EditorApplication {
    /// The diagnostics averaging window: one second, as Swift's
    /// `frameStatsDispatchInterval`.
    pub const FRAME_STATS_DISPATCH_INTERVAL: f64 = 1.0;

    pub fn current_render_stats(&self) -> RenderFrameStats {
        self.engine.current_render_stats()
    }

    pub fn current_render_scene(&self) -> RenderScene {
        self.scene.current_render_scene()
    }

    pub fn current_particle_frame_stats(&self) -> ParticleFrameStatsResource {
        self.scene.current_particle_frame_stats()
    }

    pub fn current_particle_simulation_event_apply_report(
        &self,
    ) -> ParticleSimulationEventApplyReport {
        self.scene.current_particle_simulation_event_apply_report()
    }

    pub fn current_particle_scalability_state(&self) -> ParticleScalabilityStateResource {
        self.scene.current_particle_scalability_state()
    }

    pub fn current_viewport_surface_state(&self) -> ViewportSurfaceState {
        self.engine.current_viewport_surface_state()
    }

    pub fn current_frame_stats(&self) -> EditorFrameStats {
        self.store.frame_stats()
    }

    /// One sample of the live particle pipeline, stamped with the next history
    /// index and the current frame index.
    pub fn make_particle_diagnostics_sample(&self) -> EditorParticleDiagnosticsSample {
        let stats = self.scene.current_particle_frame_stats();
        let event_report = self.scene.current_particle_simulation_event_apply_report();
        let render_summary = self.scene.current_render_scene().particle_summary;
        let render_stats = self.engine.current_render_stats();
        let next_sample_index = self
            .store
            .particle_diagnostics_history()
            .last()
            .map(|sample| sample.sample_index)
            .unwrap_or(0)
            .wrapping_add(1);
        EditorParticleDiagnosticsSample::new(
            next_sample_index,
            self.store.frame_index(),
            stats.simulated_delta_time,
            stats.emitter_count,
            stats.active_emitter_count,
            stats.live_particle_count,
            stats.live_particle_limit,
            stats.requested_spawn_count,
            stats.spawned_particle_count,
            stats.dropped_spawn_count(),
            stats.capacity_limited_spawn_count,
            stats.spawn_budget_limited_count,
            stats.spawn_budget_consumed_count,
            stats.spawn_budget_limit,
            event_report.requested_spawn_count,
            event_report.capacity_limited_spawn_count
                + event_report.spawn_budget_limited_count
                + event_report.gpu_dropped_spawn_count,
            event_report.dropped_readback_event_count,
            render_summary.cpu_render_instance_count,
            render_summary.gpu_render_instance_count,
            render_summary.cpu_batch_count,
            render_summary.gpu_batch_count,
            render_stats.gpu_particle_simulation_particle_count,
            Self::particle_gpu_workgroup_total(&render_stats),
            render_stats.gpu_particle_sort_item_count,
            render_stats.gpu_particle_sort_padded_item_count,
        )
    }

    fn particle_gpu_workgroup_total(stats: &RenderFrameStats) -> i64 {
        stats.gpu_particle_simulation_dispatch_workgroups
            + stats.gpu_particle_sort_dispatch_workgroups
            + stats.gpu_particle_instance_dispatch_workgroups
            + stats.gpu_particle_cull_dispatch_workgroups
    }

    /// Accumulates the tick gap and, once the averaging window is full, dispatches
    /// `EditorFrameStats` built from the engine's phase timings, the render
    /// thread's submit time and the last rendered frame's statistics.
    pub fn record_and_dispatch_frame_stats(&self, delta_time: f64, _simulation_delta: f64) -> bool {
        if !delta_time.is_finite() || delta_time <= 0.0 {
            return false;
        }
        self.frame_timing_accumulator
            .set(self.frame_timing_accumulator.get() + delta_time);
        self.frame_timing_count.set(self.frame_timing_count.get() + 1);
        if self.frame_timing_accumulator.get() < Self::FRAME_STATS_DISPATCH_INTERVAL {
            return false;
        }
        let phase_timings = self.engine.last_timings();
        let render_stats = self
            .last_render_frame_stats
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let last_render_submit_seconds = *self
            .last_render_submit_seconds
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let frame_seconds =
            self.frame_timing_accumulator.get() / self.frame_timing_count.get() as f64;
        let stats = EditorFrameStats::new(
            frame_seconds,
            phase_timings.input_seconds,
            phase_timings.simulation_seconds,
            phase_timings.render_prepare_seconds,
            phase_timings.render_submit_seconds,
            last_render_submit_seconds,
            render_stats.draw_call_count,
            render_stats.pass_count,
            render_stats.mesh_batch_count,
            render_stats.shadowed_light_count,
            render_stats.shadow_cascade_count,
            render_stats.shadow_map_resolution,
            render_stats.cpu_skybox_encode_ns,
            render_stats.cpu_base_encode_ns,
            render_stats.cpu_post_process_encode_ns,
        );
        self.store.dispatch(EditorAction::UpdateFrameStats(stats));
        // Reset the averaging window.
        self.frame_timing_accumulator.set(0.0);
        self.frame_timing_count.set(0);
        true
    }
}

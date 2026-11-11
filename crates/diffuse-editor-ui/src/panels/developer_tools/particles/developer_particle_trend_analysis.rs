//! Translation of
//! Editor/Sources/EditorUI/Panels/DeveloperTools/Particles/DeveloperParticleTrendAnalysis.swift.

use diffuse_editor_core::diagnostics::formatting::particle_sort_padding_overhead_for_sample;
use diffuse_editor_core::state::editor_state::EditorParticleDiagnosticsSample;

#[derive(Clone, Debug, PartialEq)]
pub struct DeveloperParticleTrendSummary {
    pub sample_count: i64,
    pub first_sample_index: u64,
    pub last_sample_index: u64,
    pub average_live_particle_count: f64,
    pub max_live_particle_count: i64,
    pub peak_live_sample_index: u64,
    pub live_budget_pressure_samples: i64,
    pub total_requested_spawn_count: i64,
    pub total_spawned_particle_count: i64,
    pub total_dropped_spawn_count: i64,
    pub total_capacity_limited_spawn_count: i64,
    pub total_spawn_budget_limited_count: i64,
    pub total_event_dropped_spawn_count: i64,
    pub total_dropped_readback_event_count: i64,
    pub peak_drop_sample_index: u64,
    pub max_dropped_spawn_count: i64,
    pub max_requested_spawn_count: i64,
    pub peak_spawn_request_sample_index: u64,
    pub max_cpu_render_instance_count: i64,
    pub max_gpu_render_instance_count: i64,
    pub max_gpu_simulation_particle_count: i64,
    pub max_gpu_workgroup_count: i64,
    pub max_sort_padding_overhead: f64,
}

pub fn make_developer_particle_trend_summary(
    history: &[EditorParticleDiagnosticsSample],
) -> Option<DeveloperParticleTrendSummary> {
    let first = history.first()?;

    let mut live_total: i64 = 0;
    let mut live_budget_pressure_samples: i64 = 0;
    let mut total_requested: i64 = 0;
    let mut total_spawned: i64 = 0;
    let mut total_dropped: i64 = 0;
    let mut total_capacity_dropped: i64 = 0;
    let mut total_budget_dropped: i64 = 0;
    let mut total_event_dropped: i64 = 0;
    let mut total_readback_dropped: i64 = 0;
    let mut peak_live_sample = first;
    let mut peak_drop_sample = first;
    let mut peak_request_sample = first;
    let mut max_cpu_render_instance_count: i64 = 0;
    let mut max_gpu_render_instance_count: i64 = 0;
    let mut max_gpu_simulation_particle_count: i64 = 0;
    let mut max_gpu_workgroup_count: i64 = 0;
    let mut max_sort_padding_overhead: f64 = 0.0;

    for sample in history {
        live_total += sample.live_particle_count;
        if sample.live_particle_limit > 0
            && sample.live_particle_count as f64 / sample.live_particle_limit as f64 >= 0.9
        {
            live_budget_pressure_samples += 1;
        }
        total_requested += sample.requested_spawn_count;
        total_spawned += sample.spawned_particle_count;
        total_dropped += sample.dropped_spawn_count;
        total_capacity_dropped += sample.capacity_limited_spawn_count;
        total_budget_dropped += sample.spawn_budget_limited_count;
        total_event_dropped += sample.event_dropped_spawn_count;
        total_readback_dropped += sample.dropped_readback_event_count;
        if sample.live_particle_count > peak_live_sample.live_particle_count {
            peak_live_sample = sample;
        }
        if sample.dropped_spawn_count > peak_drop_sample.dropped_spawn_count {
            peak_drop_sample = sample;
        }
        if sample.requested_spawn_count > peak_request_sample.requested_spawn_count {
            peak_request_sample = sample;
        }
        max_cpu_render_instance_count =
            max_cpu_render_instance_count.max(sample.cpu_render_instance_count);
        max_gpu_render_instance_count =
            max_gpu_render_instance_count.max(sample.gpu_render_instance_count);
        max_gpu_simulation_particle_count =
            max_gpu_simulation_particle_count.max(sample.gpu_simulation_particle_count);
        max_gpu_workgroup_count = max_gpu_workgroup_count.max(sample.gpu_workgroup_count);
        max_sort_padding_overhead =
            max_sort_padding_overhead.max(particle_sort_padding_overhead_for_sample(sample));
    }

    let last = history.last().unwrap_or(first);
    Some(DeveloperParticleTrendSummary {
        sample_count: history.len() as i64,
        first_sample_index: first.sample_index,
        last_sample_index: last.sample_index,
        average_live_particle_count: live_total as f64 / history.len() as f64,
        max_live_particle_count: peak_live_sample.live_particle_count,
        peak_live_sample_index: peak_live_sample.sample_index,
        live_budget_pressure_samples,
        total_requested_spawn_count: total_requested,
        total_spawned_particle_count: total_spawned,
        total_dropped_spawn_count: total_dropped,
        total_capacity_limited_spawn_count: total_capacity_dropped,
        total_spawn_budget_limited_count: total_budget_dropped,
        total_event_dropped_spawn_count: total_event_dropped,
        total_dropped_readback_event_count: total_readback_dropped,
        peak_drop_sample_index: peak_drop_sample.sample_index,
        max_dropped_spawn_count: peak_drop_sample.dropped_spawn_count,
        max_requested_spawn_count: peak_request_sample.requested_spawn_count,
        peak_spawn_request_sample_index: peak_request_sample.sample_index,
        max_cpu_render_instance_count,
        max_gpu_render_instance_count,
        max_gpu_simulation_particle_count,
        max_gpu_workgroup_count,
        max_sort_padding_overhead,
    })
}

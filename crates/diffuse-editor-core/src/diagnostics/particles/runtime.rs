//! `Editor/Sources/EditorCore/Diagnostics/Particles/Runtime.swift`.

use diffuse_render::core::render_stats::RenderFrameStats;
use diffuse_scene::particles::particle_scalability::ParticleScalabilityStateResource;
use diffuse_scene::particles::particle_simulation_event_apply_report::ParticleSimulationEventApplyReport;
use diffuse_scene::particles::particle_stats::{
    ParticleEmitterFrameStats, ParticleFrameStatsResource,
};
use diffuse_scene::rendering::render_scene::ParticleRenderSummary;

use crate::diagnostics::formatting::{
    format_budget, format_decimal, format_ms, format_percent, format_scale,
    gpu_particle_workgroup_total, particle_average_batch_size, particle_sort_padding_overhead,
};
use crate::diagnostics::particles::signals::{
    DeveloperParticleDiagnosticSeverity, DeveloperParticleDiagnosticSummary,
    DeveloperParticleEmitterHotspot,
};

pub fn make_developer_particle_emitter_hotspots(
    stats: &ParticleFrameStatsResource,
    event_report: &ParticleSimulationEventApplyReport,
    limit: i64,
) -> Vec<DeveloperParticleEmitterHotspot> {
    let entity_ids: std::collections::BTreeSet<u64> = stats
        .emitter_stats_by_entity
        .keys()
        .chain(event_report.emitter_stats_by_entity.keys())
        .copied()
        .collect();
    let mut hotspots: Vec<DeveloperParticleEmitterHotspot> = entity_ids
        .into_iter()
        .map(|entity_id| {
            make_developer_particle_emitter_hotspot(
                entity_id,
                stats.emitter_stats_for(Some(entity_id)),
                event_report.emitter_stats_for(Some(entity_id)),
            )
        })
        .collect();
    hotspots.sort_by(|lhs, rhs| {
        let lhs_severity = particle_diagnostic_severity_rank(lhs.severity);
        let rhs_severity = particle_diagnostic_severity_rank(rhs.severity);
        if lhs_severity != rhs_severity {
            return rhs_severity.cmp(&lhs_severity);
        }
        if lhs.score != rhs.score {
            return rhs.score.cmp(&lhs.score);
        }
        lhs.entity_id.cmp(&rhs.entity_id)
    });
    hotspots.truncate(limit.max(0) as usize);
    hotspots
}

/// Swift's `limit: Int = 8` default.
pub fn make_developer_particle_emitter_hotspots_with_default(
    stats: &ParticleFrameStatsResource,
    event_report: &ParticleSimulationEventApplyReport,
) -> Vec<DeveloperParticleEmitterHotspot> {
    make_developer_particle_emitter_hotspots(stats, event_report, 8)
}

fn particle_diagnostic_severity_rank(severity: DeveloperParticleDiagnosticSeverity) -> i64 {
    match severity {
        DeveloperParticleDiagnosticSeverity::Critical => 4,
        DeveloperParticleDiagnosticSeverity::Warning => 3,
        DeveloperParticleDiagnosticSeverity::Info => 2,
        DeveloperParticleDiagnosticSeverity::Nominal => 1,
        DeveloperParticleDiagnosticSeverity::Idle => 0,
    }
}

pub fn make_developer_particle_emitter_hotspot(
    entity_id: u64,
    frame_stats: Option<ParticleEmitterFrameStats>,
    event_stats: Option<ParticleEmitterFrameStats>,
) -> DeveloperParticleEmitterHotspot {
    let Some(base_stats) = frame_stats.or(event_stats) else {
        return DeveloperParticleEmitterHotspot {
            entity_id,
            severity: DeveloperParticleDiagnosticSeverity::Idle,
            reason: "Idle".to_string(),
            primary_signal: "No particle frame or event stats".to_string(),
            recommendation:
                "Select an active particle emitter or play the scene to collect runtime diagnostics."
                    .to_string(),
            details: Vec::new(),
            score: 0,
            live_particle_count: 0,
            requested_spawn_count: 0,
            spawned_particle_count: 0,
            dropped_spawn_count: 0,
            capacity_limited_spawn_count: 0,
            spawn_budget_limited_count: 0,
            event_dropped_spawn_count: 0,
            live_budget_text: format_budget(0, 0),
            spawn_budget_text: format_budget(0, 0),
        };
    };
    let event_drops = event_stats
        .map(|stats| stats.dropped_spawn_count())
        .unwrap_or(0);
    let frame_drops = frame_stats
        .map(|stats| stats.dropped_spawn_count())
        .unwrap_or(0);
    let capacity_drops = frame_stats
        .map(|stats| stats.capacity_limited_spawn_count)
        .unwrap_or(0)
        + event_stats
            .map(|stats| stats.capacity_limited_spawn_count)
            .unwrap_or(0);
    let budget_drops = frame_stats
        .map(|stats| stats.spawn_budget_limited_count)
        .unwrap_or(0)
        + event_stats
            .map(|stats| stats.spawn_budget_limited_count)
            .unwrap_or(0);
    let total_drops = frame_drops + event_drops;
    let requested = frame_stats
        .map(|stats| stats.requested_spawn_count)
        .unwrap_or(0)
        + event_stats
            .map(|stats| stats.requested_spawn_count)
            .unwrap_or(0);
    let spawned = frame_stats
        .map(|stats| stats.spawned_particle_count())
        .unwrap_or(0)
        + event_stats
            .map(|stats| stats.spawned_particle_count())
            .unwrap_or(0);
    let live_count = frame_stats
        .map(|stats| stats.live_particle_count)
        .unwrap_or(base_stats.live_particle_count);
    let live_pressure = frame_stats
        .map(|stats| stats.live_particle_budget_utilization())
        .unwrap_or_else(|| base_stats.live_particle_budget_utilization());
    let live_pressure_score = (live_pressure * 10_000.0).round() as i64;
    let live_budget_text = format_budget(live_count, base_stats.live_particle_budget_limit());
    let spawn_budget_text = format_budget(
        frame_stats
            .map(|stats| stats.spawn_budget_consumed_count)
            .unwrap_or(0)
            + event_stats
                .map(|stats| stats.spawn_budget_consumed_count)
                .unwrap_or(0),
        base_stats.spawn_budget_limit,
    );
    let score = total_drops * 1_000_000 + live_pressure_score + requested * 100 + live_count;

    let (severity, reason, primary_signal, recommendation, details) = if capacity_drops > 0 {
        (
            DeveloperParticleDiagnosticSeverity::Critical,
            "Capacity drops".to_string(),
            format!("{capacity_drops} capacity-limited spawns"),
            "Raise this emitter's max particles/effective budget or lower lifetime and high-rate spawn sources.".to_string(),
            vec![
                format!("Live {live_budget_text}"),
                format!("Frame drops {frame_drops}, event drops {event_drops}"),
            ],
        )
    } else if budget_drops > 0 {
        (
            DeveloperParticleDiagnosticSeverity::Warning,
            "Spawn budget drops".to_string(),
            format!("{budget_drops} spawn-budget drops"),
            "Raise Max Spawn / Frame for this emitter or reduce burst, distance, and sub-emitter rates."
                .to_string(),
            vec![
                format!("Spawn budget {spawn_budget_text}"),
                format!("Requested {requested}, accepted {spawned}"),
            ],
        )
    } else if live_pressure >= 0.9 {
        (
            DeveloperParticleDiagnosticSeverity::Warning,
            "Live budget".to_string(),
            format!(
                "{} live budget used",
                format_percent(live_count, base_stats.live_particle_budget_limit())
            ),
            "Reduce lifetime or spawn rate before this emitter starts dropping new particles."
                .to_string(),
            vec![
                format!("Live {live_budget_text}"),
                format!("Requested {requested}, accepted {spawned}"),
            ],
        )
    } else if requested > 0 {
        (
            DeveloperParticleDiagnosticSeverity::Info,
            "High spawn requests".to_string(),
            format!("{requested} spawn requests"),
            "Audit emission curves, bursts, and distance emission if this emitter becomes a frame hotspot."
                .to_string(),
            vec![
                format!("Accepted {spawned}"),
                format!("Live {live_budget_text}"),
            ],
        )
    } else if live_count > 0 {
        (
            DeveloperParticleDiagnosticSeverity::Nominal,
            "Live particles".to_string(),
            format!("{live_count} live particles"),
            "Emitter is active without spawn pressure in the latest frame.".to_string(),
            vec![
                format!("Live {live_budget_text}"),
                format!("Spawn budget {spawn_budget_text}"),
            ],
        )
    } else {
        (
            DeveloperParticleDiagnosticSeverity::Idle,
            "Idle".to_string(),
            "No live particles or spawn requests".to_string(),
            "Emitter has no particle workload in the latest frame.".to_string(),
            vec![
                format!("Live {live_budget_text}"),
                format!("Spawn budget {spawn_budget_text}"),
            ],
        )
    };

    DeveloperParticleEmitterHotspot {
        entity_id,
        severity,
        reason,
        primary_signal,
        recommendation,
        details,
        score,
        live_particle_count: live_count,
        requested_spawn_count: requested,
        spawned_particle_count: spawned,
        dropped_spawn_count: total_drops,
        capacity_limited_spawn_count: capacity_drops,
        spawn_budget_limited_count: budget_drops,
        event_dropped_spawn_count: event_drops,
        live_budget_text,
        spawn_budget_text,
    }
}

/// Swift's `eventStats: ParticleEmitterFrameStats? = nil` default.
pub fn make_developer_particle_emitter_hotspot_with_default(
    entity_id: u64,
    frame_stats: Option<ParticleEmitterFrameStats>,
) -> DeveloperParticleEmitterHotspot {
    make_developer_particle_emitter_hotspot(entity_id, frame_stats, None)
}

pub fn make_developer_particle_diagnostic_summary(
    stats: &ParticleFrameStatsResource,
    event_report: &ParticleSimulationEventApplyReport,
    scalability: &ParticleScalabilityStateResource,
    render_summary: &ParticleRenderSummary,
    render_stats: &RenderFrameStats,
) -> DeveloperParticleDiagnosticSummary {
    let frame_capacity_drops = stats.capacity_limited_spawn_count;
    let event_capacity_drops = event_report.capacity_limited_spawn_count;
    let frame_budget_drops = stats.spawn_budget_limited_count;
    let event_budget_drops = event_report.spawn_budget_limited_count;
    let has_capacity_drops = frame_capacity_drops > 0 || event_capacity_drops > 0;
    let has_budget_drops = frame_budget_drops > 0 || event_budget_drops > 0;
    let has_readback_drops = event_report.dropped_readback_event_count > 0;
    let live_pressure = stats.live_particle_budget_utilization();

    if has_readback_drops {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Critical,
            status: "GPU event readback overflow".to_string(),
            primary_signal: format!(
                "{} dropped readback events",
                event_report.dropped_readback_event_count
            ),
            recommendation:
                "Reduce event-heavy GPU particles or raise the GPU event readback capacity."
                    .to_string(),
            details: vec![
                format!(
                    "Readback {}/{} events applied",
                    event_report.applied_event_count, event_report.total_readback_event_count
                ),
                format!(
                    "Sub-emitter spawns {}",
                    event_report.sub_emitter_spawned_count
                ),
            ],
        };
    }

    if has_capacity_drops {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Critical,
            status: "Particle capacity saturated".to_string(),
            primary_signal: format!(
                "{} capacity-limited spawns",
                frame_capacity_drops + event_capacity_drops
            ),
            recommendation:
                "Raise max particles/effective budget or reduce lifetime and high-rate spawn sources."
                    .to_string(),
            details: vec![
                format!(
                    "Live {}/{}",
                    stats.live_particle_count,
                    stats.live_particle_budget_limit
                ),
                format!(
                    "Frame drops {}, event drops {}",
                    stats.dropped_spawn_count(), event_report.dropped_spawn_count()
                ),
            ],
        };
    }

    if has_budget_drops {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Warning,
            status: "Spawn budget throttling".to_string(),
            primary_signal: format!(
                "{} budget-limited spawns",
                frame_budget_drops + event_budget_drops
            ),
            recommendation:
                "Raise Max Spawn / Frame for bursty emitters or reduce burst, distance, and sub-emitter rates."
                    .to_string(),
            details: vec![
                format!(
                    "Frame budget {}",
                    format_budget(stats.spawn_budget_consumed_count, stats.spawn_budget_limit)
                ),
                format!(
                    "Event budget {}",
                    format_budget(
                        event_report.spawn_budget_consumed_count,
                        event_report.spawn_budget_limit
                    )
                ),
            ],
        };
    }

    if live_pressure >= 0.9 {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Warning,
            status: "Live particle budget near full".to_string(),
            primary_signal: format!(
                "{} live budget used",
                format_percent(stats.live_particle_count, stats.live_particle_budget_limit)
            ),
            recommendation:
                "Reduce lifetime/spawn rates or raise the live-particle scalability budget before drops start."
                    .to_string(),
            details: vec![
                format!(
                    "Live {}/{}",
                    stats.live_particle_count, stats.live_particle_budget_limit
                ),
                format!(
                    "Scalability {} @ {}",
                    scalability.reason.raw_value(),
                    format_scale(scalability.pressure)
                ),
            ],
        };
    }

    let sort_padding_overhead = particle_sort_padding_overhead(render_stats);
    if sort_padding_overhead >= 0.5 && render_stats.gpu_particle_sort_item_count >= 512 {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Warning,
            status: "GPU sort padding overhead".to_string(),
            primary_signal: format!(
                "{} padding",
                format_percent(
                    render_stats.gpu_particle_sort_padded_item_count
                        - render_stats.gpu_particle_sort_item_count,
                    render_stats.gpu_particle_sort_padded_item_count
                )
            ),
            recommendation:
                "Reduce sorted GPU particles or split effects so sort passes work on tighter batches."
                    .to_string(),
            details: vec![
                format!("Sort items {}", render_stats.gpu_particle_sort_item_count),
                format!(
                    "Sort workgroups {}",
                    render_stats.gpu_particle_sort_dispatch_workgroups
                ),
            ],
        };
    }

    if render_summary.render_budget_skipped_source_particle_count > 0 {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Info,
            status: "Particle render budget limiting".to_string(),
            primary_signal: format!(
                "{} source particles skipped before render",
                render_summary.render_budget_skipped_source_particle_count
            ),
            recommendation:
                "Tune Max Rendered Particles and render LOD so simulation cost and visual density stay balanced."
                    .to_string(),
            details: vec![
                format!(
                    "Source {}, submitted {}",
                    render_summary.source_particle_count,
                    render_summary.submitted_source_particle_count
                ),
                format!("Render instances {}", render_summary.particle_count),
            ],
        };
    }

    let average_batch_size = particle_average_batch_size(render_summary);
    if render_summary.batch_count >= 8 && average_batch_size < 4.0 {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Info,
            status: "Particle batches fragmented".to_string(),
            primary_signal: format!(
                "{} batches for {} particles",
                render_summary.batch_count, render_summary.particle_count
            ),
            recommendation:
                "Align blend mode, texture, and sort priority across related emitters to improve batching."
                    .to_string(),
            details: vec![
                format!("Average {} particles/batch", format_decimal(average_batch_size)),
                format!(
                    "Textures {}, CPU/GPU {}/{}",
                    render_summary.unique_texture_count,
                    render_summary.cpu_batch_count,
                    render_summary.gpu_batch_count
                ),
            ],
        };
    }

    if stats.active_emitter_count == 0 && render_summary.particle_count == 0 {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Idle,
            status: "No active particle workload".to_string(),
            primary_signal: "No live particles or submitted batches".to_string(),
            recommendation: "Select or enable a particle emitter to inspect runtime behavior."
                .to_string(),
            details: vec![
                format!("Emitters {}", stats.emitter_count),
                format!(
                    "Frame sample {}",
                    format_ms(f64::from(stats.simulated_delta_time) * 1000.0)
                ),
            ],
        };
    }

    if render_summary.gpu_render_instance_count > 0 {
        return DeveloperParticleDiagnosticSummary {
            severity: DeveloperParticleDiagnosticSeverity::Nominal,
            status: "GPU particle path active".to_string(),
            primary_signal: format!(
                "{} GPU render instances",
                render_summary.gpu_render_instance_count
            ),
            recommendation:
                "Watch sort padding, readback drops, and GPU workgroup split as effect complexity grows."
                    .to_string(),
            details: vec![
                format!("GPU batches {}", render_summary.gpu_batch_count),
                format!("GPU workgroups {}", gpu_particle_workgroup_total(render_stats)),
            ],
        };
    }

    DeveloperParticleDiagnosticSummary {
        severity: DeveloperParticleDiagnosticSeverity::Nominal,
        status: "CPU particle path active".to_string(),
        primary_signal: format!(
            "{} CPU render instances",
            render_summary.cpu_render_instance_count
        ),
        recommendation:
            "Move high-volume compatible emitters to GPU simulation when CPU particles become a bottleneck."
                .to_string(),
        details: vec![
            format!("CPU batches {}", render_summary.cpu_batch_count),
            format!("Live particles {}", stats.live_particle_count),
        ],
    }
}

//! `Editor/Sources/EditorCore/Diagnostics/Issues/Assessment.swift`.
//!
//! Turns the latest frame, render, particle and console signals into the ranked
//! issue list the developer panels show.

use diffuse_render::core::render_stats::RenderFrameStats;

use crate::diagnostics::formatting::{
    bottleneck, cpu_ms, format_fps, format_ms, format_ns, format_signed_ms,
};
use crate::diagnostics::frame::trend::make_developer_frame_trend_summary;
use crate::diagnostics::issues::diagnostic_issue::{
    DeveloperDiagnosticArea, DeveloperDiagnosticIssue, DeveloperDiagnosticScope,
    DeveloperDiagnosticSeverity, DeveloperDiagnosticTarget,
};
use crate::diagnostics::particles::signals::{
    DeveloperParticleDiagnosticSeverity, DeveloperParticleDiagnosticSummary,
    DeveloperParticleEmitterHotspot,
};
use crate::diagnostics::rendering::passes::make_developer_render_pass_breakdown;
use crate::state::editor_state::{
    EditorConsoleEntry, EditorConsoleSeverity, EditorFrameStats, EditorFrameStatsHistorySample,
};

pub fn make_developer_workbench_issues(
    frame_stats: &EditorFrameStats,
    frame_history: &[EditorFrameStatsHistorySample],
    render_stats: &RenderFrameStats,
    particle_summary: Option<&DeveloperParticleDiagnosticSummary>,
    particle_authoring_summary: Option<&DeveloperParticleDiagnosticSummary>,
    particle_hotspots: &[DeveloperParticleEmitterHotspot],
    selected_entity_id: Option<u64>,
    console_entries: &[EditorConsoleEntry],
) -> Vec<DeveloperDiagnosticIssue> {
    let mut issues: Vec<DeveloperDiagnosticIssue> = Vec::new();
    let latest_sample_index = frame_history.last().map(|sample| sample.sample_index);

    if frame_stats.is_frame_pacing_dominated() {
        issues.push(DeveloperDiagnosticIssue {
            id: "frame.pacing".to_string(),
            severity: DeveloperDiagnosticSeverity::Warning,
            scope: DeveloperDiagnosticScope::Frame,
            title: "Frame pacing gap".to_string(),
            primary_signal: format!(
                "{} waiting/idle in latest tick",
                format_ms(frame_stats.pacing_gap_ms())
            ),
            evidence: vec![
                format!("Observed FPS {}", format_fps(frame_stats.fps)),
                format!("Work FPS {}", format_fps(frame_stats.work_fps())),
                format!("Work {}", format_ms(frame_stats.work_ms())),
            ],
            recommendation: "Treat this as event-loop or viewport pacing first; rendering work is not the primary explanation until work time rises.".to_string(),
            target: DeveloperDiagnosticTarget {
                area: DeveloperDiagnosticArea::Frame,
                frame_sample_index: latest_sample_index,
                label: "Open Frame".to_string(),
            },
        });
    } else if frame_stats.work_ms() > 33.3 {
        issues.push(DeveloperDiagnosticIssue {
            id: "frame.work.30fps".to_string(),
            severity: DeveloperDiagnosticSeverity::Critical,
            scope: DeveloperDiagnosticScope::Frame,
            title: "Frame work exceeds 30 FPS budget".to_string(),
            primary_signal: format!("Work {}", format_ms(frame_stats.work_ms())),
            evidence: vec![
                format!("CPU {}", format_ms(cpu_ms(frame_stats))),
                format!(
                    "GPU / present {}",
                    format_ms(frame_stats.gpu_present_seconds * 1000.0)
                ),
                format!("Likely {}", bottleneck(frame_stats)),
            ],
            recommendation: "Inspect the selected frame breakdown before changing quality settings; the bottleneck label only points to the first layer.".to_string(),
            target: DeveloperDiagnosticTarget {
                area: DeveloperDiagnosticArea::Frame,
                frame_sample_index: latest_sample_index,
                label: "Open Frame".to_string(),
            },
        });
    } else if frame_stats.work_ms() > 16.7 {
        issues.push(DeveloperDiagnosticIssue {
            id: "frame.work.60fps".to_string(),
            severity: DeveloperDiagnosticSeverity::Warning,
            scope: DeveloperDiagnosticScope::Frame,
            title: "Frame work exceeds 60 FPS budget".to_string(),
            primary_signal: format!("Work {}", format_ms(frame_stats.work_ms())),
            evidence: vec![
                format!("Headroom @60 {}", format_signed_ms(16.7 - frame_stats.work_ms())),
                format!("Likely {}", bottleneck(frame_stats)),
            ],
            recommendation: "Use the frame timeline to find whether this is a one-frame spike or sustained frame pressure.".to_string(),
            target: DeveloperDiagnosticTarget {
                area: DeveloperDiagnosticArea::Frame,
                frame_sample_index: latest_sample_index,
                label: "Open Frame".to_string(),
            },
        });
    }

    if let Some(trend) = make_developer_frame_trend_summary(frame_history)
        && trend.sample_count >= 8
        && trend.p95_work_ms > 16.7
    {
        issues.push(DeveloperDiagnosticIssue {
            id: "frame.trend.p95".to_string(),
            severity: if trend.p95_work_ms > 33.3 {
                DeveloperDiagnosticSeverity::Critical
            } else {
                DeveloperDiagnosticSeverity::Warning
            },
            scope: DeveloperDiagnosticScope::Frame,
            title: "Sustained frame-time pressure".to_string(),
            primary_signal: format!(
                "P95 work {} over {} samples",
                format_ms(trend.p95_work_ms),
                trend.sample_count
            ),
            evidence: vec![
                format!("Average work {}", format_ms(trend.average_work_ms)),
                format!("Peak sample #{}", trend.peak_work_sample_index),
                format!(
                    "Pacing-dominated {}/{}",
                    trend.pacing_dominated_samples, trend.sample_count
                ),
            ],
            recommendation: "Open the peak sample and compare it with the latest frame before tuning render or simulation settings.".to_string(),
            target: DeveloperDiagnosticTarget {
                area: DeveloperDiagnosticArea::Frame,
                frame_sample_index: Some(trend.peak_work_sample_index),
                label: "Open Peak Frame".to_string(),
            },
        });
    }

    if render_stats.cpu_encode_ns > 16_700_000 {
        issues.push(DeveloperDiagnosticIssue {
            id: "render.encode".to_string(),
            severity: if render_stats.cpu_encode_ns > 33_300_000 {
                DeveloperDiagnosticSeverity::Critical
            } else {
                DeveloperDiagnosticSeverity::Warning
            },
            scope: DeveloperDiagnosticScope::Render,
            title: "Render encode exceeds frame budget".to_string(),
            primary_signal: format!("Encode {}", format_ns(render_stats.cpu_encode_ns)),
            evidence: vec![
                format!("Draw calls {}", render_stats.draw_call_count),
                format!("Passes {}", render_stats.pass_count),
                format!("Mesh batches {}", render_stats.mesh_batch_count),
            ],
            recommendation: "Open the render debugger and inspect pass encode time before reducing scene content broadly.".to_string(),
            target: DeveloperDiagnosticTarget {
                area: DeveloperDiagnosticArea::Render,
                frame_sample_index: None,
                label: "Open Render".to_string(),
            },
        });
    }

    let pass_breakdown = make_developer_render_pass_breakdown(render_stats);
    if let Some(slow_pass) = pass_breakdown
        .iter()
        .find(|pass| pass.encode_ns > 8_000_000)
    {
        issues.push(DeveloperDiagnosticIssue {
            id: format!("render.pass.{}", slow_pass.name),
            severity: if slow_pass.encode_ns > 16_700_000 {
                DeveloperDiagnosticSeverity::Critical
            } else {
                DeveloperDiagnosticSeverity::Warning
            },
            scope: DeveloperDiagnosticScope::Render,
            title: format!("{} pass is expensive", slow_pass.name),
            primary_signal: format!("Encode {}", format_ns(slow_pass.encode_ns)),
            evidence: vec![
                format!("Draw calls {}", slow_pass.draw_call_count),
                slow_pass.signal.clone(),
            ],
            recommendation: slow_pass.recommendation.clone(),
            target: DeveloperDiagnosticTarget {
                area: DeveloperDiagnosticArea::Render,
                frame_sample_index: None,
                label: "Open Render".to_string(),
            },
        });
    }

    if let Some(particle_summary) = particle_summary
        && particle_summary.severity != DeveloperParticleDiagnosticSeverity::Nominal
        && particle_summary.severity != DeveloperParticleDiagnosticSeverity::Idle
    {
        issues.push(DeveloperDiagnosticIssue {
            id: format!("particles.health.{}", particle_summary.status),
            severity: developer_diagnostic_severity_from(particle_summary.severity),
            scope: DeveloperDiagnosticScope::Particles,
            title: particle_summary.status.clone(),
            primary_signal: particle_summary.primary_signal.clone(),
            evidence: particle_summary.details.clone(),
            recommendation: particle_summary.recommendation.clone(),
            target: DeveloperDiagnosticTarget {
                area: DeveloperDiagnosticArea::Particles,
                frame_sample_index: None,
                label: "Open Particles".to_string(),
            },
        });
    }

    if let Some(particle_authoring_summary) = particle_authoring_summary
        && selected_entity_id.is_some()
        && particle_authoring_summary.severity != DeveloperParticleDiagnosticSeverity::Nominal
        && particle_authoring_summary.severity != DeveloperParticleDiagnosticSeverity::Idle
    {
        issues.push(DeveloperDiagnosticIssue {
            id: format!("particles.authoring.{}", particle_authoring_summary.status),
            severity: developer_diagnostic_severity_from(particle_authoring_summary.severity),
            scope: DeveloperDiagnosticScope::Particles,
            title: particle_authoring_summary.status.clone(),
            primary_signal: particle_authoring_summary.primary_signal.clone(),
            evidence: particle_authoring_summary.details.clone(),
            recommendation: particle_authoring_summary.recommendation.clone(),
            target: DeveloperDiagnosticTarget {
                area: DeveloperDiagnosticArea::Particles,
                frame_sample_index: None,
                label: "Open Particles".to_string(),
            },
        });
    }

    if let Some(hotspot) = particle_hotspots.first()
        && (hotspot.severity == DeveloperParticleDiagnosticSeverity::Critical
            || hotspot.severity == DeveloperParticleDiagnosticSeverity::Warning)
    {
        issues.push(DeveloperDiagnosticIssue {
            id: format!("particles.hotspot.{}", hotspot.entity_id),
            severity: developer_diagnostic_severity_from(hotspot.severity),
            scope: DeveloperDiagnosticScope::Particles,
            title: format!("Emitter hotspot #{}", hotspot.entity_id),
            primary_signal: hotspot.primary_signal.clone(),
            evidence: hotspot.details.clone(),
            recommendation: hotspot.recommendation.clone(),
            target: DeveloperDiagnosticTarget {
                area: DeveloperDiagnosticArea::Particles,
                frame_sample_index: None,
                label: "Open Particles".to_string(),
            },
        });
    }

    let error_count = console_entries
        .iter()
        .filter(|entry| entry.severity == EditorConsoleSeverity::Error)
        .count();
    let warning_count = console_entries
        .iter()
        .filter(|entry| entry.severity == EditorConsoleSeverity::Warning)
        .count();
    if error_count > 0 {
        issues.push(DeveloperDiagnosticIssue {
            id: "console.errors".to_string(),
            severity: DeveloperDiagnosticSeverity::Critical,
            scope: DeveloperDiagnosticScope::Console,
            title: "Console errors".to_string(),
            primary_signal: format!(
                "{error_count} error{} recorded",
                if error_count == 1 { "" } else { "s" }
            ),
            evidence: console_entries
                .iter()
                .rev()
                .filter(|entry| entry.severity == EditorConsoleSeverity::Error)
                .take(3)
                .map(|entry| entry.message.clone())
                .collect(),
            recommendation: "Open the console and resolve the newest errors before interpreting downstream runtime symptoms.".to_string(),
            target: DeveloperDiagnosticTarget {
                area: DeveloperDiagnosticArea::Console,
                frame_sample_index: None,
                label: "Open Console".to_string(),
            },
        });
    } else if warning_count > 0 {
        issues.push(DeveloperDiagnosticIssue {
            id: "console.warnings".to_string(),
            severity: DeveloperDiagnosticSeverity::Warning,
            scope: DeveloperDiagnosticScope::Console,
            title: "Console warnings".to_string(),
            primary_signal: format!(
                "{warning_count} warning{} recorded",
                if warning_count == 1 { "" } else { "s" }
            ),
            evidence: console_entries
                .iter()
                .rev()
                .filter(|entry| entry.severity == EditorConsoleSeverity::Warning)
                .take(3)
                .map(|entry| entry.message.clone())
                .collect(),
            recommendation: "Review the newest warnings and correlate them with the active scene or selected entity.".to_string(),
            target: DeveloperDiagnosticTarget {
                area: DeveloperDiagnosticArea::Console,
                frame_sample_index: None,
                label: "Open Console".to_string(),
            },
        });
    }

    if issues.is_empty() {
        issues.push(DeveloperDiagnosticIssue {
            id: "workbench.nominal".to_string(),
            severity: DeveloperDiagnosticSeverity::Nominal,
            scope: DeveloperDiagnosticScope::State,
            title: "No blocking diagnostics".to_string(),
            primary_signal:
                "Latest frame, render, particles, and console signals are nominal".to_string(),
            evidence: vec![
                format!("Work {}", format_ms(frame_stats.work_ms())),
                format!("Draw calls {}", frame_stats.draw_call_count),
                format!("Console entries {}", console_entries.len()),
            ],
            recommendation: "Use Profiler and Monitors as the entry points, then drill into Render or Particles for subsystem-specific evidence.".to_string(),
            target: DeveloperDiagnosticTarget {
                area: DeveloperDiagnosticArea::Frame,
                frame_sample_index: latest_sample_index,
                label: "Open Frame".to_string(),
            },
        });
    }

    issues.sort_by(developer_diagnostic_issue_order);
    issues
}

fn developer_diagnostic_severity_from(
    severity: DeveloperParticleDiagnosticSeverity,
) -> DeveloperDiagnosticSeverity {
    match severity {
        DeveloperParticleDiagnosticSeverity::Critical => DeveloperDiagnosticSeverity::Critical,
        DeveloperParticleDiagnosticSeverity::Warning => DeveloperDiagnosticSeverity::Warning,
        DeveloperParticleDiagnosticSeverity::Info => DeveloperDiagnosticSeverity::Info,
        DeveloperParticleDiagnosticSeverity::Nominal
        | DeveloperParticleDiagnosticSeverity::Idle => DeveloperDiagnosticSeverity::Nominal,
    }
}

fn developer_diagnostic_issue_order(
    lhs: &DeveloperDiagnosticIssue,
    rhs: &DeveloperDiagnosticIssue,
) -> std::cmp::Ordering {
    let lhs_rank = developer_diagnostic_severity_rank(lhs.severity);
    let rhs_rank = developer_diagnostic_severity_rank(rhs.severity);
    if lhs_rank != rhs_rank {
        return rhs_rank.cmp(&lhs_rank);
    }
    let lhs_scope = lhs.scope.raw_value();
    let rhs_scope = rhs.scope.raw_value();
    if lhs_scope != rhs_scope {
        return lhs_scope.cmp(rhs_scope);
    }
    lhs.id.cmp(&rhs.id)
}

pub fn developer_diagnostic_severity_rank(severity: DeveloperDiagnosticSeverity) -> i64 {
    match severity {
        DeveloperDiagnosticSeverity::Critical => 4,
        DeveloperDiagnosticSeverity::Warning => 3,
        DeveloperDiagnosticSeverity::Info => 2,
        DeveloperDiagnosticSeverity::Nominal => 1,
    }
}

//! Translation of
//! Editor/Sources/EditorUI/Panels/DeveloperTools/Trace/DeveloperTraceBuilder.swift.

use diffuse_editor_core::diagnostics::formatting::{
    format_fps, format_ms, format_ns, format_percent,
};
use diffuse_editor_core::diagnostics::issues::assessment::developer_diagnostic_severity_rank;
use diffuse_editor_core::diagnostics::issues::diagnostic_issue::{
    DeveloperDiagnosticArea, DeveloperDiagnosticIssue, DeveloperDiagnosticScope,
    DeveloperDiagnosticSeverity, DeveloperDiagnosticTarget,
};
use diffuse_editor_core::diagnostics::rendering::passes::{
    DeveloperRenderPassInspection, make_developer_render_pass_breakdown,
};
use diffuse_editor_core::state::editor_state::{
    EditorConsoleEntry, EditorConsoleSeverity, EditorFrameStats, EditorFrameStatsHistorySample,
    EditorParticleDiagnosticsSample,
};
use diffuse_render::core::render_stats::RenderFrameStats;

use super::super::models::developer_trace_models::{
    DeveloperTraceEvent, DeveloperTraceMode, DeveloperTraceSample, DeveloperTraceSnapshot,
    DeveloperTraceTrack,
};

#[allow(clippy::too_many_arguments)]
pub fn make_developer_trace(
    frame_stats: &EditorFrameStats,
    frame_history: &[EditorFrameStatsHistorySample],
    particle_history: &[EditorParticleDiagnosticsSample],
    render_stats: &RenderFrameStats,
    issues: &[DeveloperDiagnosticIssue],
    console_entries: &[EditorConsoleEntry],
    mode: DeveloperTraceMode,
    max_samples: usize,
) -> DeveloperTraceSnapshot {
    let limit = max_samples.max(1);
    let clipped_frame_history: Vec<&EditorFrameStatsHistorySample> =
        frame_history.iter().rev().take(limit).rev().collect();
    let mut samples: Vec<DeveloperTraceSample> = if clipped_frame_history.is_empty() {
        vec![DeveloperTraceSample {
            sample_index: 0,
            frame_index: 0,
            frame_stats: frame_stats.clone(),
            particle_live_count: 0,
            particle_dropped_count: 0,
            console_severity: None,
            issue_ids: Vec::new(),
        }]
    } else {
        let particle_samples: std::collections::BTreeMap<u64, &EditorParticleDiagnosticsSample> =
            particle_history
                .iter()
                .rev()
                .take(limit)
                .map(|sample| (sample.sample_index, sample))
                .collect();
        clipped_frame_history
            .into_iter()
            .map(|sample| {
                let particle_sample = particle_samples.get(&sample.sample_index).copied();
                DeveloperTraceSample {
                    sample_index: sample.sample_index,
                    frame_index: sample.frame_index,
                    frame_stats: sample.stats.clone(),
                    particle_live_count: particle_sample
                        .map(|sample| sample.live_particle_count)
                        .unwrap_or(0),
                    particle_dropped_count: particle_sample
                        .map(developer_particle_trace_drop_count)
                        .unwrap_or(0),
                    console_severity: None,
                    issue_ids: Vec::new(),
                }
            })
            .collect()
    };

    let latest_sample_index = samples
        .last()
        .map(|sample| sample.sample_index)
        .unwrap_or(0);
    if let Some(console_severity) = developer_trace_console_severity(console_entries)
        && let Some(last) = samples.last_mut()
    {
        last.console_severity = Some(console_severity);
    }

    let mut events: Vec<DeveloperTraceEvent> = Vec::new();
    events.extend(developer_frame_trace_events(&samples));
    events.extend(developer_particle_trace_events(
        particle_history,
        latest_sample_index,
        limit,
    ));
    events.extend(developer_console_trace_events(
        console_entries,
        latest_sample_index,
    ));

    let render_passes = make_developer_render_pass_breakdown(render_stats);
    events.extend(developer_render_pass_trace_events(
        &render_passes,
        latest_sample_index,
    ));
    events.extend(issues.iter().map(|issue| {
        DeveloperTraceEvent {
            id: format!("issue.{}", issue.id),
            track: developer_trace_track(issue.scope),
            sample_index: issue
                .target
                .frame_sample_index
                .unwrap_or(latest_sample_index),
            severity: issue.severity,
            scope: issue.scope,
            title: issue.title.clone(),
            primary_signal: issue.primary_signal.clone(),
            evidence: issue.evidence.clone(),
            recommendation: issue.recommendation.clone(),
            target: issue.target.clone(),
        }
    }));

    let mut event_ids_by_sample: std::collections::BTreeMap<u64, Vec<String>> =
        std::collections::BTreeMap::new();
    for event in &events {
        event_ids_by_sample
            .entry(event.sample_index)
            .or_default()
            .push(event.id.clone());
    }
    for sample in &mut samples {
        sample.issue_ids = event_ids_by_sample
            .get(&sample.sample_index)
            .cloned()
            .unwrap_or_default();
    }

    events.sort_by(developer_trace_event_precedes);
    DeveloperTraceSnapshot {
        mode,
        samples,
        events,
        render_passes,
        issues: issues.to_vec(),
    }
}

fn developer_frame_trace_events(samples: &[DeveloperTraceSample]) -> Vec<DeveloperTraceEvent> {
    samples
        .iter()
        .filter_map(|sample| {
            let stats = &sample.frame_stats;
            let (severity, title, signal, recommendation) = if stats.work_ms() > 33.3 {
                (
                    DeveloperDiagnosticSeverity::Critical,
                    "Frame over 30 FPS budget",
                    format!("Work {}", format_ms(stats.work_ms())),
                    "Open the frame breakdown and compare CPU, GPU present, and pacing before tuning content.",
                )
            } else if stats.work_ms() > 16.7 {
                (
                    DeveloperDiagnosticSeverity::Warning,
                    "Frame over 60 FPS budget",
                    format!("Work {}", format_ms(stats.work_ms())),
                    "Check whether this is a spike or sustained pressure across neighboring frames.",
                )
            } else if stats.is_frame_pacing_dominated() {
                (
                    DeveloperDiagnosticSeverity::Warning,
                    "Frame pacing gap",
                    format!("{} waiting/idle", format_ms(stats.pacing_gap_ms())),
                    "Treat this as event-loop or viewport pacing before assuming render overload.",
                )
            } else {
                return None;
            };
            Some(DeveloperTraceEvent {
                id: format!("frame.{}", sample.sample_index),
                track: DeveloperTraceTrack::Frame,
                sample_index: sample.sample_index,
                severity,
                scope: DeveloperDiagnosticScope::Frame,
                title: title.to_string(),
                primary_signal: signal,
                evidence: vec![
                    format!("Observed FPS {}", format_fps(stats.fps)),
                    format!("Work FPS {}", format_fps(stats.work_fps())),
                    format!("Pacing Gap {}", format_ms(stats.pacing_gap_ms())),
                ],
                recommendation: recommendation.to_string(),
                target: DeveloperDiagnosticTarget::new(
                    DeveloperDiagnosticArea::Frame,
                    Some(sample.sample_index),
                    "Open Frame",
                ),
            })
        })
        .collect()
}

fn developer_particle_trace_events(
    particle_history: &[EditorParticleDiagnosticsSample],
    latest_sample_index: u64,
    max_samples: usize,
) -> Vec<DeveloperTraceEvent> {
    particle_history
        .iter()
        .rev()
        .take(max_samples.max(1))
        .rev()
        .filter_map(|sample| {
            let drop_count = developer_particle_trace_drop_count(sample);
            let near_limit = sample.live_particle_limit > 0
                && sample.live_particle_count as f64 / sample.live_particle_limit as f64 >= 0.9;
            if !(drop_count > 0 || sample.dropped_readback_event_count > 0 || near_limit) {
                return None;
            }
            let severity = if sample.dropped_readback_event_count > 0
                || sample.capacity_limited_spawn_count > 0
            {
                DeveloperDiagnosticSeverity::Critical
            } else {
                DeveloperDiagnosticSeverity::Warning
            };
            let (title, signal) = if sample.dropped_readback_event_count > 0 {
                (
                    "Particle readback overflow",
                    format!(
                        "{} dropped readback events",
                        sample.dropped_readback_event_count
                    ),
                )
            } else if drop_count > 0 {
                (
                    "Particle spawn drops",
                    format!("{drop_count} dropped spawns"),
                )
            } else {
                (
                    "Particle live budget pressure",
                    format!(
                        "{} live budget used",
                        format_percent(sample.live_particle_count, sample.live_particle_limit)
                    ),
                )
            };
            Some(DeveloperTraceEvent {
                id: format!("particles.{}", sample.sample_index),
                track: DeveloperTraceTrack::Particles,
                sample_index: if sample.sample_index == 0 {
                    latest_sample_index
                } else {
                    sample.sample_index
                },
                severity,
                scope: DeveloperDiagnosticScope::Particles,
                title: title.to_string(),
                primary_signal: signal,
                evidence: vec![
                    format!(
                        "Live {}/{}",
                        sample.live_particle_count, sample.live_particle_limit
                    ),
                    format!(
                        "Requested {}, spawned {}",
                        sample.requested_spawn_count, sample.spawned_particle_count
                    ),
                    format!(
                        "CPU/GPU render {}/{}",
                        sample.cpu_render_instance_count, sample.gpu_render_instance_count
                    ),
                ],
                recommendation: "Open Particles to inspect emitter hotspots, budget drops, GPU fallback, and render skips.".to_string(),
                target: DeveloperDiagnosticTarget::new(
                    DeveloperDiagnosticArea::Particles,
                    Some(sample.sample_index),
                    "Open Particles",
                ),
            })
        })
        .collect()
}

fn developer_console_trace_events(
    console_entries: &[EditorConsoleEntry],
    latest_sample_index: u64,
) -> Vec<DeveloperTraceEvent> {
    let Some(severity) = developer_trace_console_severity(console_entries) else {
        return Vec::new();
    };
    if severity != DeveloperDiagnosticSeverity::Critical
        && severity != DeveloperDiagnosticSeverity::Warning
    {
        return Vec::new();
    }
    let filtered: Vec<&EditorConsoleEntry> = console_entries
        .iter()
        .rev()
        .filter(|entry| {
            if severity == DeveloperDiagnosticSeverity::Critical {
                entry.severity == EditorConsoleSeverity::Error
            } else {
                entry.severity == EditorConsoleSeverity::Warning
            }
        })
        .collect();
    let count = filtered.len();
    let title = if severity == DeveloperDiagnosticSeverity::Critical {
        "Console errors"
    } else {
        "Console warnings"
    };
    let noun = if severity == DeveloperDiagnosticSeverity::Critical {
        "error"
    } else {
        "warning"
    };
    vec![DeveloperTraceEvent {
        id: format!(
            "console.latest.{}",
            developer_console_severity_label(severity)
        ),
        track: DeveloperTraceTrack::Console,
        sample_index: latest_sample_index,
        severity,
        scope: DeveloperDiagnosticScope::Console,
        title: title.to_string(),
        primary_signal: format!("{count} {noun}{}", if count == 1 { "" } else { "s" }),
        evidence: filtered
            .iter()
            .take(3)
            .map(|entry| entry.message.clone())
            .collect(),
        recommendation:
            "Open Console and resolve the newest messages before interpreting downstream symptoms."
                .to_string(),
        target: DeveloperDiagnosticTarget::new(
            DeveloperDiagnosticArea::Console,
            None,
            "Open Console",
        ),
    }]
}

fn developer_render_pass_trace_events(
    render_passes: &[DeveloperRenderPassInspection],
    latest_sample_index: u64,
) -> Vec<DeveloperTraceEvent> {
    render_passes
        .iter()
        .filter(|pass| pass.encode_ns > 8_000_000)
        .map(|pass| {
            let severity = if pass.encode_ns > 16_700_000 {
                DeveloperDiagnosticSeverity::Critical
            } else {
                DeveloperDiagnosticSeverity::Warning
            };
            DeveloperTraceEvent {
                id: format!("renderPass.{}", pass.name),
                track: DeveloperTraceTrack::RenderPass,
                sample_index: latest_sample_index,
                severity,
                scope: DeveloperDiagnosticScope::Render,
                title: format!("{} pass cost", pass.name),
                primary_signal: pass.signal.clone(),
                evidence: vec![
                    format!("Encode {}", format_ns(pass.encode_ns)),
                    format!("Draw calls {}", pass.draw_call_count),
                ],
                recommendation: pass.recommendation.clone(),
                target: DeveloperDiagnosticTarget::new(
                    DeveloperDiagnosticArea::Render,
                    None,
                    "Open Render",
                ),
            }
        })
        .collect()
}

fn developer_trace_console_severity(
    entries: &[EditorConsoleEntry],
) -> Option<DeveloperDiagnosticSeverity> {
    if entries
        .iter()
        .any(|entry| entry.severity == EditorConsoleSeverity::Error)
    {
        return Some(DeveloperDiagnosticSeverity::Critical);
    }
    if entries
        .iter()
        .any(|entry| entry.severity == EditorConsoleSeverity::Warning)
    {
        return Some(DeveloperDiagnosticSeverity::Warning);
    }
    if entries
        .iter()
        .any(|entry| entry.severity == EditorConsoleSeverity::Info)
    {
        return Some(DeveloperDiagnosticSeverity::Info);
    }
    None
}

pub fn developer_trace_track(scope: DeveloperDiagnosticScope) -> DeveloperTraceTrack {
    match scope {
        DeveloperDiagnosticScope::Frame => DeveloperTraceTrack::Frame,
        DeveloperDiagnosticScope::Render => DeveloperTraceTrack::RenderPass,
        DeveloperDiagnosticScope::Particles => DeveloperTraceTrack::Particles,
        DeveloperDiagnosticScope::Console => DeveloperTraceTrack::Console,
        DeveloperDiagnosticScope::State => DeveloperTraceTrack::Cpu,
    }
}

/// Ascending sample order used by `makeDeveloperTrace` when it sorts events.
pub fn developer_trace_event_precedes(
    lhs: &DeveloperTraceEvent,
    rhs: &DeveloperTraceEvent,
) -> std::cmp::Ordering {
    lhs.sample_index
        .cmp(&rhs.sample_index)
        .then_with(|| {
            developer_diagnostic_severity_rank(rhs.severity)
                .cmp(&developer_diagnostic_severity_rank(lhs.severity))
        })
        .then_with(|| lhs.track.raw_value().cmp(rhs.track.raw_value()))
        .then_with(|| lhs.id.cmp(&rhs.id))
}

fn developer_particle_trace_drop_count(sample: &EditorParticleDiagnosticsSample) -> i64 {
    sample.dropped_spawn_count
        + sample.capacity_limited_spawn_count
        + sample.spawn_budget_limited_count
        + sample.event_dropped_spawn_count
}

fn developer_console_severity_label(severity: DeveloperDiagnosticSeverity) -> &'static str {
    match severity {
        DeveloperDiagnosticSeverity::Nominal => "Nominal",
        DeveloperDiagnosticSeverity::Info => "Info",
        DeveloperDiagnosticSeverity::Warning => "Warning",
        DeveloperDiagnosticSeverity::Critical => "Critical",
    }
}

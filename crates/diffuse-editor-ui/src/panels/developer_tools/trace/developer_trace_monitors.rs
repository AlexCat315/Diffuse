//! Translation of
//! Editor/Sources/EditorUI/Panels/DeveloperTools/Trace/DeveloperTraceMonitors.swift.
//!
//! Builds one monitor snapshot per trace track. The Swift helpers were `private`
//! to the file; they are `pub` here so the trace panel can reuse the exact same
//! status/empty-filter/baseline text.

use cove_ui_compose::primitives::data::chart::model::ChartMark;
use cove_ui_compose::theme::SemanticColorRef;
use diffuse_editor_core::diagnostics::formatting::cpu_ms;
use diffuse_editor_core::diagnostics::issues::assessment::developer_diagnostic_severity_rank;

use super::super::models::developer_monitor_snapshot::DeveloperMonitorSnapshot;
use super::super::models::developer_trace_models::{
    DeveloperTraceEventSortOrder, DeveloperTraceInvestigationSummary, DeveloperTraceSample,
    DeveloperTraceSeverityFilter, DeveloperTraceSnapshot, DeveloperTraceTrack,
};
use super::developer_trace_queries::developer_trace_track_latest_signal;

pub fn developer_trace_monitor_title(track: DeveloperTraceTrack) -> &'static str {
    match track {
        DeveloperTraceTrack::Frame => "FPS / Frame",
        DeveloperTraceTrack::Cpu => "CPU",
        DeveloperTraceTrack::GpuPresent => "GPU / Present",
        DeveloperTraceTrack::RenderPass => "Render Passes",
        DeveloperTraceTrack::Particles => "Particles",
        DeveloperTraceTrack::Console => "Console / Issues",
    }
}

pub fn developer_trace_monitor_series(
    track: DeveloperTraceTrack,
    trace: &DeveloperTraceSnapshot,
) -> Vec<f32> {
    match track {
        DeveloperTraceTrack::Frame => trace
            .samples
            .iter()
            .map(|sample| sample.frame_stats.work_ms() as f32)
            .collect(),
        DeveloperTraceTrack::Cpu => trace
            .samples
            .iter()
            .map(|sample| cpu_ms(&sample.frame_stats) as f32)
            .collect(),
        DeveloperTraceTrack::GpuPresent => trace
            .samples
            .iter()
            .map(|sample| (sample.frame_stats.gpu_present_seconds * 1000.0) as f32)
            .collect(),
        DeveloperTraceTrack::RenderPass => trace
            .render_passes
            .iter()
            .map(|pass| (pass.encode_ns as f64 / 1_000_000.0) as f32)
            .collect(),
        DeveloperTraceTrack::Particles => trace
            .samples
            .iter()
            .map(|sample| {
                sample
                    .particle_live_count
                    .max(sample.particle_dropped_count) as f32
            })
            .collect(),
        DeveloperTraceTrack::Console => trace
            .samples
            .iter()
            .map(|sample| {
                sample.issue_ids.len().max(
                    sample
                        .console_severity
                        .map(developer_diagnostic_severity_rank)
                        .unwrap_or(0) as usize,
                ) as f32
            })
            .collect(),
    }
}

pub fn developer_trace_monitor_limit(track: DeveloperTraceTrack) -> Option<f32> {
    match track {
        DeveloperTraceTrack::Frame => Some(16.7),
        DeveloperTraceTrack::Cpu => Some(10.0),
        DeveloperTraceTrack::GpuPresent => Some(10.0),
        DeveloperTraceTrack::RenderPass => Some(2.0),
        DeveloperTraceTrack::Particles => None,
        DeveloperTraceTrack::Console => Some(1.0),
    }
}

pub fn developer_trace_monitor_color(track: DeveloperTraceTrack) -> SemanticColorRef {
    match track {
        DeveloperTraceTrack::Frame => SemanticColorRef::accent(),
        DeveloperTraceTrack::Cpu => SemanticColorRef::info(),
        DeveloperTraceTrack::GpuPresent => SemanticColorRef::warning(),
        DeveloperTraceTrack::RenderPass => SemanticColorRef::on_surface(),
        DeveloperTraceTrack::Particles => SemanticColorRef::success(),
        DeveloperTraceTrack::Console => SemanticColorRef::error(),
    }
}

pub fn developer_trace_monitor_mode(track: DeveloperTraceTrack) -> ChartMark {
    match track {
        DeveloperTraceTrack::Frame
        | DeveloperTraceTrack::Cpu
        | DeveloperTraceTrack::GpuPresent
        | DeveloperTraceTrack::Particles => ChartMark::Line,
        DeveloperTraceTrack::RenderPass | DeveloperTraceTrack::Console => ChartMark::Bar,
    }
}

pub fn developer_trace_monitor_range_label(values: &[f32]) -> String {
    let Some(min_value) = values.iter().copied().reduce(f32::min) else {
        return "min -- max --".to_string();
    };
    let max_value = values.iter().copied().reduce(f32::max).unwrap_or(min_value);
    format!(
        "min {} max {}",
        developer_trace_monitor_format(min_value),
        developer_trace_monitor_format(max_value)
    )
}

pub fn developer_trace_monitor_format(value: f32) -> String {
    if value >= 100.0 {
        return format!("{value:.0}");
    }
    if value >= 10.0 {
        return format!("{value:.1}");
    }
    format!("{value:.2}")
}

pub fn developer_trace_monitor_sample_label(
    track: DeveloperTraceTrack,
    trace: &DeveloperTraceSnapshot,
) -> String {
    match track {
        DeveloperTraceTrack::RenderPass => format!("{} passes", trace.render_passes.len()),
        _ => format!("{} samples", trace.samples.len()),
    }
}

pub fn make_developer_monitor_snapshots(
    trace: &DeveloperTraceSnapshot,
) -> Vec<DeveloperMonitorSnapshot> {
    DeveloperTraceTrack::ALL
        .iter()
        .map(|track| make_developer_monitor_snapshot(*track, trace))
        .collect()
}

pub fn make_developer_monitor_snapshot(
    track: DeveloperTraceTrack,
    trace: &DeveloperTraceSnapshot,
) -> DeveloperMonitorSnapshot {
    let values = developer_trace_monitor_series(track, trace);
    let current = developer_monitor_current_value(track, &values);
    let limit = developer_trace_monitor_limit(track);
    DeveloperMonitorSnapshot {
        track,
        title: developer_trace_monitor_title(track).to_string(),
        current_value: current,
        current_label: developer_trace_track_latest_signal(track, trace.samples.last(), trace),
        range_label: developer_trace_monitor_range_label(&values),
        sample_label: developer_trace_monitor_sample_label(track, trace),
        limit,
        is_over_limit: limit
            .is_some_and(|threshold| current.is_some_and(|value| value > threshold)),
        values,
    }
}

pub fn developer_monitor_current_value(track: DeveloperTraceTrack, values: &[f32]) -> Option<f32> {
    match track {
        DeveloperTraceTrack::RenderPass => values.iter().copied().reduce(f32::max),
        _ => values.last().copied(),
    }
}

pub fn developer_trace_status_text(
    summary: &DeveloperTraceInvestigationSummary,
    track_filter: Option<DeveloperTraceTrack>,
    severity_filter: DeveloperTraceSeverityFilter,
    sort_order: DeveloperTraceEventSortOrder,
    selected_sample_index: Option<u64>,
) -> String {
    let track_text = track_filter
        .map(|track| track.raw_value().to_string())
        .unwrap_or_else(|| "all tracks".to_string());
    let selected_text = selected_sample_index
        .map(|index| format!("selected #{index}"))
        .unwrap_or_else(|| "no selection".to_string());
    let hot_text = summary
        .hot_sample_index
        .map(|index| format!("hot #{index} x{}", summary.hot_sample_event_count))
        .unwrap_or_else(|| "no hot sample".to_string());
    format!(
        "{} events | {} errors | {} warnings | {hot_text} | {track_text} | {} | {} | {selected_text}",
        summary.visible_event_count,
        summary.critical_count,
        summary.warning_count,
        severity_filter.raw_value(),
        sort_order.raw_value()
    )
}

pub fn developer_trace_empty_filter_text(
    query: &str,
    track_filter: Option<DeveloperTraceTrack>,
    severity_filter: DeveloperTraceSeverityFilter,
) -> String {
    let mut parts: Vec<String> = Vec::new();
    let trimmed = query.trim();
    if !trimmed.is_empty() {
        parts.push(format!("search \"{trimmed}\""));
    }
    if let Some(track_filter) = track_filter {
        parts.push(format!("track {}", track_filter.raw_value()));
    }
    if severity_filter != DeveloperTraceSeverityFilter::All {
        parts.push(format!("severity {}", severity_filter.raw_value()));
    }
    if parts.is_empty() {
        return "The trace window has no projected events yet.".to_string();
    }
    format!("Active filters: {}.", parts.join(", "))
}

pub fn developer_trace_baseline_sample(
    sample: &DeveloperTraceSample,
    baseline_trace: Option<&DeveloperTraceSnapshot>,
) -> Option<DeveloperTraceSample> {
    let baseline_trace = baseline_trace?;
    baseline_trace
        .samples
        .iter()
        .find(|candidate| candidate.sample_index == sample.sample_index)
        .or_else(|| baseline_trace.samples.last())
        .cloned()
}

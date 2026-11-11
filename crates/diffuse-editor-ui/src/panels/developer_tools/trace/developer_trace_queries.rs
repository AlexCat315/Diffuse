//! Translation of
//! Editor/Sources/EditorUI/Panels/DeveloperTools/Trace/DeveloperTraceQueries.swift.
//!
//! Read-only derivations over a `DeveloperTraceSnapshot`: filtered/sorted event
//! lists, per-cell severity and glyphs, and the sample investigation/context
//! rows the trace panel renders.

use std::cmp::Ordering;
use std::collections::BTreeMap;

use cove_ui_compose::theme::SemanticColorRef;
use diffuse_editor_core::diagnostics::formatting::{
    cpu_ms, format_ms, format_ns, frame_budget_glyph,
};
use diffuse_editor_core::diagnostics::issues::assessment::developer_diagnostic_severity_rank;
use diffuse_editor_core::diagnostics::issues::diagnostic_issue::{
    DeveloperDiagnosticIssue, DeveloperDiagnosticSeverity, DeveloperDiagnosticTarget,
};

use super::super::models::developer_trace_models::{
    DeveloperTraceEvent, DeveloperTraceEventSortOrder, DeveloperTraceInvestigationSummary,
    DeveloperTraceNavigationDirection, DeveloperTraceSample, DeveloperTraceSampleContext,
    DeveloperTraceSampleContextPosition, DeveloperTraceSampleContextRow,
    DeveloperTraceSampleInvestigation, DeveloperTraceSeverityFilter, DeveloperTraceSnapshot,
    DeveloperTraceTrack,
};
use super::super::shared::developer_diagnostic_colors::{
    developer_diagnostic_background, developer_diagnostic_border, developer_diagnostic_foreground,
};
use super::developer_trace_builder::developer_trace_track;

pub fn developer_selected_trace_event(
    trace: &DeveloperTraceSnapshot,
    selected_event_id: Option<&str>,
) -> Option<DeveloperTraceEvent> {
    let selected_event_id = selected_event_id?;
    trace
        .events
        .iter()
        .find(|event| event.id == selected_event_id)
        .cloned()
}

pub fn developer_selected_trace_sample(
    trace: &DeveloperTraceSnapshot,
    selected_sample_index: Option<u64>,
    selected_event: Option<&DeveloperTraceEvent>,
) -> Option<DeveloperTraceSample> {
    let sample_index = selected_event
        .map(|event| event.sample_index)
        .or(selected_sample_index);
    match sample_index {
        None => trace.samples.last().cloned(),
        Some(index) => trace
            .samples
            .iter()
            .find(|sample| sample.sample_index == index)
            .or_else(|| trace.samples.last())
            .cloned(),
    }
}

pub fn developer_trace_sample_events(
    trace: &DeveloperTraceSnapshot,
    sample_index: u64,
    excluding: Option<&str>,
) -> Vec<DeveloperTraceEvent> {
    let mut events: Vec<DeveloperTraceEvent> = trace
        .events
        .iter()
        .filter(|event| event.sample_index == sample_index && Some(event.id.as_str()) != excluding)
        .cloned()
        .collect();
    events.sort_by(|lhs, rhs| {
        let lhs_rank = developer_diagnostic_severity_rank(lhs.severity);
        let rhs_rank = developer_diagnostic_severity_rank(rhs.severity);
        rhs_rank
            .cmp(&lhs_rank)
            .then_with(|| lhs.track.raw_value().cmp(rhs.track.raw_value()))
            .then_with(|| lhs.id.cmp(&rhs.id))
    });
    events
}

pub fn developer_trace_cell_severity(
    track: DeveloperTraceTrack,
    sample: &DeveloperTraceSample,
    events: &[DeveloperTraceEvent],
) -> DeveloperDiagnosticSeverity {
    if let Some(event) = events.iter().max_by(|lhs, rhs| {
        developer_diagnostic_severity_rank(lhs.severity)
            .cmp(&developer_diagnostic_severity_rank(rhs.severity))
    }) {
        return event.severity;
    }
    match track {
        DeveloperTraceTrack::Frame => {
            if sample.frame_stats.work_ms() > 33.3 {
                DeveloperDiagnosticSeverity::Critical
            } else if sample.frame_stats.work_ms() > 16.7
                || sample.frame_stats.is_frame_pacing_dominated()
            {
                DeveloperDiagnosticSeverity::Warning
            } else {
                DeveloperDiagnosticSeverity::Nominal
            }
        }
        DeveloperTraceTrack::Cpu => {
            let cpu = cpu_ms(&sample.frame_stats);
            if cpu > 20.0 {
                DeveloperDiagnosticSeverity::Critical
            } else if cpu > 10.0 {
                DeveloperDiagnosticSeverity::Warning
            } else {
                DeveloperDiagnosticSeverity::Nominal
            }
        }
        DeveloperTraceTrack::GpuPresent => {
            let present = sample.frame_stats.gpu_present_seconds * 1000.0;
            if present > 20.0 {
                DeveloperDiagnosticSeverity::Critical
            } else if present > 10.0 {
                DeveloperDiagnosticSeverity::Warning
            } else {
                DeveloperDiagnosticSeverity::Nominal
            }
        }
        DeveloperTraceTrack::RenderPass => DeveloperDiagnosticSeverity::Nominal,
        DeveloperTraceTrack::Particles => {
            if sample.particle_dropped_count > 0 {
                DeveloperDiagnosticSeverity::Warning
            } else {
                DeveloperDiagnosticSeverity::Nominal
            }
        }
        DeveloperTraceTrack::Console => sample
            .console_severity
            .unwrap_or(DeveloperDiagnosticSeverity::Nominal),
    }
}

pub fn developer_trace_cell_glyph(
    track: DeveloperTraceTrack,
    sample: &DeveloperTraceSample,
    events: &[DeveloperTraceEvent],
) -> String {
    if let Some(event) = events.iter().max_by(|lhs, rhs| {
        developer_diagnostic_severity_rank(lhs.severity)
            .cmp(&developer_diagnostic_severity_rank(rhs.severity))
    }) {
        return developer_trace_severity_glyph(event.severity).to_string();
    }
    match track {
        DeveloperTraceTrack::Frame => {
            let glyph = frame_budget_glyph(&sample.frame_stats);
            if glyph == "." { String::new() } else { glyph }
        }
        DeveloperTraceTrack::Cpu => {
            if cpu_ms(&sample.frame_stats) > 10.0 {
                "C".to_string()
            } else {
                String::new()
            }
        }
        DeveloperTraceTrack::GpuPresent => {
            if sample.frame_stats.gpu_present_seconds * 1000.0 > 10.0 {
                "G".to_string()
            } else {
                String::new()
            }
        }
        DeveloperTraceTrack::RenderPass => String::new(),
        DeveloperTraceTrack::Particles => {
            if sample.particle_dropped_count > 0 {
                "P".to_string()
            } else {
                String::new()
            }
        }
        DeveloperTraceTrack::Console => sample
            .console_severity
            .map(|severity| developer_trace_severity_glyph(severity).to_string())
            .unwrap_or_default(),
    }
}

pub fn developer_trace_cell_background(
    track: DeveloperTraceTrack,
    sample: &DeveloperTraceSample,
    severity: DeveloperDiagnosticSeverity,
) -> SemanticColorRef {
    if severity != DeveloperDiagnosticSeverity::Nominal {
        return developer_diagnostic_background(severity);
    }
    match track {
        DeveloperTraceTrack::Frame => {
            if sample.frame_stats.work_ms() > 8.0 {
                SemanticColorRef::surface_floating()
            } else {
                SemanticColorRef::surface_sunken()
            }
        }
        DeveloperTraceTrack::Cpu => {
            if cpu_ms(&sample.frame_stats) > 5.0 {
                SemanticColorRef::surface_floating()
            } else {
                SemanticColorRef::surface_sunken()
            }
        }
        DeveloperTraceTrack::GpuPresent => {
            if sample.frame_stats.gpu_present_seconds * 1000.0 > 5.0 {
                SemanticColorRef::surface_floating()
            } else {
                SemanticColorRef::surface_sunken()
            }
        }
        DeveloperTraceTrack::RenderPass
        | DeveloperTraceTrack::Particles
        | DeveloperTraceTrack::Console => SemanticColorRef::surface_sunken(),
    }
}

pub fn developer_trace_cell_foreground(severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    if severity == DeveloperDiagnosticSeverity::Nominal {
        SemanticColorRef::on_surface_muted()
    } else {
        developer_diagnostic_foreground(severity)
    }
}

pub fn developer_trace_cell_border(severity: DeveloperDiagnosticSeverity) -> SemanticColorRef {
    if severity == DeveloperDiagnosticSeverity::Nominal {
        SemanticColorRef::divider()
    } else {
        developer_diagnostic_border(severity)
    }
}

pub fn developer_trace_cell_border_width(
    severity: DeveloperDiagnosticSeverity,
    is_selected: bool,
) -> f32 {
    if is_selected {
        return 2.0;
    }
    if severity == DeveloperDiagnosticSeverity::Nominal {
        0.0
    } else {
        1.0
    }
}

pub fn developer_trace_severity_glyph(severity: DeveloperDiagnosticSeverity) -> &'static str {
    match severity {
        DeveloperDiagnosticSeverity::Critical => "!",
        DeveloperDiagnosticSeverity::Warning => "^",
        DeveloperDiagnosticSeverity::Info => "i",
        DeveloperDiagnosticSeverity::Nominal => "",
    }
}

pub fn developer_trace_window_label(samples: &[DeveloperTraceSample]) -> String {
    let (Some(first), Some(last)) = (samples.first(), samples.last()) else {
        return "empty".to_string();
    };
    format!("#{}-#{}", first.sample_index, last.sample_index)
}

pub fn developer_trace_visible_events(
    trace: &DeveloperTraceSnapshot,
    query: &str,
    track_filter: Option<DeveloperTraceTrack>,
    severity_filter: DeveloperTraceSeverityFilter,
    sort_order: DeveloperTraceEventSortOrder,
) -> Vec<DeveloperTraceEvent> {
    let trimmed = query.trim();
    let mut events: Vec<DeveloperTraceEvent> = trace
        .events
        .iter()
        .filter(|event| {
            developer_trace_event_matches_track(event, track_filter)
                && developer_trace_event_matches_severity(event, severity_filter)
                && (trimmed.is_empty() || developer_trace_event_matches_query(event, trimmed))
        })
        .cloned()
        .collect();
    events.sort_by(|lhs, rhs| {
        if developer_trace_event_precedes_with_order(lhs, rhs, sort_order) {
            Ordering::Less
        } else if developer_trace_event_precedes_with_order(rhs, lhs, sort_order) {
            Ordering::Greater
        } else {
            Ordering::Equal
        }
    });
    events
}

pub fn developer_trace_event_precedes_with_order(
    lhs: &DeveloperTraceEvent,
    rhs: &DeveloperTraceEvent,
    sort_order: DeveloperTraceEventSortOrder,
) -> bool {
    let lhs_rank = developer_diagnostic_severity_rank(lhs.severity);
    let rhs_rank = developer_diagnostic_severity_rank(rhs.severity);
    match sort_order {
        DeveloperTraceEventSortOrder::Newest => {
            if lhs.sample_index != rhs.sample_index {
                return lhs.sample_index > rhs.sample_index;
            }
            if lhs_rank != rhs_rank {
                return lhs_rank > rhs_rank;
            }
            if lhs.track.raw_value() != rhs.track.raw_value() {
                return lhs.track.raw_value() < rhs.track.raw_value();
            }
            lhs.id < rhs.id
        }
        DeveloperTraceEventSortOrder::Severity => {
            if lhs_rank != rhs_rank {
                return lhs_rank > rhs_rank;
            }
            if lhs.sample_index != rhs.sample_index {
                return lhs.sample_index > rhs.sample_index;
            }
            if lhs.track.raw_value() != rhs.track.raw_value() {
                return lhs.track.raw_value() < rhs.track.raw_value();
            }
            lhs.id < rhs.id
        }
        DeveloperTraceEventSortOrder::Track => {
            if lhs.track.raw_value() != rhs.track.raw_value() {
                return lhs.track.raw_value() < rhs.track.raw_value();
            }
            if lhs.sample_index != rhs.sample_index {
                return lhs.sample_index > rhs.sample_index;
            }
            if lhs_rank != rhs_rank {
                return lhs_rank > rhs_rank;
            }
            lhs.id < rhs.id
        }
    }
}

pub fn developer_trace_adjacent_event_id(
    events: &[DeveloperTraceEvent],
    selected_event_id: Option<&str>,
    direction: DeveloperTraceNavigationDirection,
) -> Option<String> {
    if events.is_empty() {
        return None;
    }
    let Some(index) =
        selected_event_id.and_then(|id| events.iter().position(|event| event.id == id))
    else {
        return events.first().map(|event| event.id.clone());
    };
    match direction {
        DeveloperTraceNavigationDirection::Previous => {
            Some(events[index.saturating_sub(1)].id.clone())
        }
        DeveloperTraceNavigationDirection::Next => {
            Some(events[(index + 1).min(events.len() - 1)].id.clone())
        }
    }
}

pub fn make_developer_trace_investigation_summary(
    events: &[DeveloperTraceEvent],
) -> DeveloperTraceInvestigationSummary {
    let critical_count = events
        .iter()
        .filter(|event| event.severity == DeveloperDiagnosticSeverity::Critical)
        .count() as i64;
    let warning_count = events
        .iter()
        .filter(|event| event.severity == DeveloperDiagnosticSeverity::Warning)
        .count() as i64;
    let mut grouped: BTreeMap<u64, usize> = BTreeMap::new();
    for event in events {
        *grouped.entry(event.sample_index).or_insert(0) += 1;
    }
    let hot_sample = grouped
        .iter()
        .max_by(|(lhs_index, lhs_count), (rhs_index, rhs_count)| {
            lhs_count
                .cmp(rhs_count)
                .then_with(|| lhs_index.cmp(rhs_index))
        })
        .map(|(index, count)| (*index, *count));
    let focus_event_id = events
        .iter()
        .find(|event| event.severity == DeveloperDiagnosticSeverity::Critical)
        .or_else(|| {
            events
                .iter()
                .find(|event| event.severity == DeveloperDiagnosticSeverity::Warning)
        })
        .or_else(|| events.first())
        .map(|event| event.id.clone());
    DeveloperTraceInvestigationSummary {
        visible_event_count: events.len() as i64,
        critical_count,
        warning_count,
        hot_sample_index: hot_sample.map(|(index, _)| index),
        hot_sample_event_count: hot_sample.map(|(_, count)| count as i64).unwrap_or(0),
        focus_event_id,
    }
}

pub fn make_developer_trace_sample_investigation(
    trace: &DeveloperTraceSnapshot,
    sample_index: u64,
) -> DeveloperTraceSampleInvestigation {
    let events = developer_trace_sample_events(trace, sample_index, None);
    let targets = developer_trace_unique_targets(&events);
    DeveloperTraceSampleInvestigation {
        sample_index,
        lead_event_id: events.first().map(|event| event.id.clone()),
        event_count: events.len() as i64,
        critical_count: events
            .iter()
            .filter(|event| event.severity == DeveloperDiagnosticSeverity::Critical)
            .count() as i64,
        warning_count: events
            .iter()
            .filter(|event| event.severity == DeveloperDiagnosticSeverity::Warning)
            .count() as i64,
        tracks: developer_trace_unique_tracks(&events),
        drilldown_targets: targets,
    }
}

pub fn make_developer_trace_sample_context(
    trace: &DeveloperTraceSnapshot,
    sample_index: u64,
) -> Option<DeveloperTraceSampleContext> {
    let selected_index = trace
        .samples
        .iter()
        .position(|sample| sample.sample_index == sample_index)?;
    let selected_sample = &trace.samples[selected_index];
    let selected_work_ms = selected_sample.frame_stats.work_ms();
    Some(DeveloperTraceSampleContext {
        previous: if selected_index > 0 {
            Some(developer_trace_sample_context_row(
                DeveloperTraceSampleContextPosition::Previous,
                &trace.samples[selected_index - 1],
                selected_work_ms,
                trace,
            ))
        } else {
            None
        },
        selected: developer_trace_sample_context_row(
            DeveloperTraceSampleContextPosition::Selected,
            selected_sample,
            selected_work_ms,
            trace,
        ),
        next: if selected_index + 1 < trace.samples.len() {
            Some(developer_trace_sample_context_row(
                DeveloperTraceSampleContextPosition::Next,
                &trace.samples[selected_index + 1],
                selected_work_ms,
                trace,
            ))
        } else {
            None
        },
    })
}

fn developer_trace_sample_context_row(
    position: DeveloperTraceSampleContextPosition,
    sample: &DeveloperTraceSample,
    selected_work_ms: f64,
    trace: &DeveloperTraceSnapshot,
) -> DeveloperTraceSampleContextRow {
    let events = developer_trace_sample_events(trace, sample.sample_index, None);
    DeveloperTraceSampleContextRow {
        position,
        sample_index: sample.sample_index,
        work_ms: sample.frame_stats.work_ms(),
        work_delta_from_selected_ms: sample.frame_stats.work_ms() - selected_work_ms,
        event_count: events.len() as i64,
        highest_severity: developer_trace_highest_severity(&events),
    }
}

fn developer_trace_unique_tracks(events: &[DeveloperTraceEvent]) -> Vec<DeveloperTraceTrack> {
    let mut tracks: Vec<DeveloperTraceTrack> = Vec::new();
    for event in events {
        if !tracks.contains(&event.track) {
            tracks.push(event.track);
        }
    }
    tracks
}

fn developer_trace_unique_targets(
    events: &[DeveloperTraceEvent],
) -> Vec<DeveloperDiagnosticTarget> {
    let mut targets: Vec<DeveloperDiagnosticTarget> = Vec::new();
    for event in events {
        if !targets.contains(&event.target) {
            targets.push(event.target.clone());
        }
    }
    targets
}

pub fn developer_trace_visible_issues(
    trace: &DeveloperTraceSnapshot,
    query: &str,
    track_filter: Option<DeveloperTraceTrack>,
    severity_filter: DeveloperTraceSeverityFilter,
) -> Vec<DeveloperDiagnosticIssue> {
    let trimmed = query.trim();
    trace
        .issues
        .iter()
        .filter(|issue| {
            developer_trace_issue_matches_track(issue, track_filter)
                && developer_trace_issue_matches_severity(issue, severity_filter)
                && (trimmed.is_empty() || developer_trace_issue_matches_query(issue, trimmed))
        })
        .cloned()
        .collect()
}

pub fn developer_trace_visible_tracks(
    track_filter: Option<DeveloperTraceTrack>,
) -> Vec<DeveloperTraceTrack> {
    match track_filter {
        Some(track) => vec![track],
        None => DeveloperTraceTrack::ALL.to_vec(),
    }
}

fn developer_trace_event_matches_query(event: &DeveloperTraceEvent, query: &str) -> bool {
    let needle = query.to_lowercase();
    let matches = |text: &str| text.to_lowercase().contains(&needle);
    matches(&event.title)
        || matches(&event.primary_signal)
        || matches(event.track.raw_value())
        || matches(event.scope.raw_value())
        || event.evidence.iter().any(|text| matches(text))
        || matches(&event.recommendation)
}

fn developer_trace_event_matches_track(
    event: &DeveloperTraceEvent,
    track_filter: Option<DeveloperTraceTrack>,
) -> bool {
    track_filter.is_none_or(|track| event.track == track)
}

fn developer_trace_event_matches_severity(
    event: &DeveloperTraceEvent,
    filter: DeveloperTraceSeverityFilter,
) -> bool {
    match filter {
        DeveloperTraceSeverityFilter::All => true,
        DeveloperTraceSeverityFilter::Problems => {
            event.severity == DeveloperDiagnosticSeverity::Critical
                || event.severity == DeveloperDiagnosticSeverity::Warning
        }
        DeveloperTraceSeverityFilter::Critical => {
            event.severity == DeveloperDiagnosticSeverity::Critical
        }
        DeveloperTraceSeverityFilter::Warning => {
            event.severity == DeveloperDiagnosticSeverity::Warning
        }
    }
}

fn developer_trace_issue_matches_query(issue: &DeveloperDiagnosticIssue, query: &str) -> bool {
    let needle = query.to_lowercase();
    let matches = |text: &str| text.to_lowercase().contains(&needle);
    matches(&issue.title)
        || matches(&issue.primary_signal)
        || matches(issue.scope.raw_value())
        || issue.evidence.iter().any(|text| matches(text))
        || matches(&issue.recommendation)
}

fn developer_trace_issue_matches_track(
    issue: &DeveloperDiagnosticIssue,
    track_filter: Option<DeveloperTraceTrack>,
) -> bool {
    track_filter.is_none_or(|track| developer_trace_track(issue.scope) == track)
}

fn developer_trace_issue_matches_severity(
    issue: &DeveloperDiagnosticIssue,
    filter: DeveloperTraceSeverityFilter,
) -> bool {
    match filter {
        DeveloperTraceSeverityFilter::All => true,
        DeveloperTraceSeverityFilter::Problems => {
            issue.severity == DeveloperDiagnosticSeverity::Critical
                || issue.severity == DeveloperDiagnosticSeverity::Warning
        }
        DeveloperTraceSeverityFilter::Critical => {
            issue.severity == DeveloperDiagnosticSeverity::Critical
        }
        DeveloperTraceSeverityFilter::Warning => {
            issue.severity == DeveloperDiagnosticSeverity::Warning
        }
    }
}

pub fn developer_trace_track_icon(track: DeveloperTraceTrack) -> &'static str {
    match track {
        DeveloperTraceTrack::Frame => "F",
        DeveloperTraceTrack::Cpu => "C",
        DeveloperTraceTrack::GpuPresent => "G",
        DeveloperTraceTrack::RenderPass => "R",
        DeveloperTraceTrack::Particles => "P",
        DeveloperTraceTrack::Console => ">",
    }
}

fn developer_trace_highest_severity(events: &[DeveloperTraceEvent]) -> DeveloperDiagnosticSeverity {
    events
        .iter()
        .max_by(|lhs, rhs| {
            developer_diagnostic_severity_rank(lhs.severity)
                .cmp(&developer_diagnostic_severity_rank(rhs.severity))
        })
        .map(|event| event.severity)
        .unwrap_or(DeveloperDiagnosticSeverity::Nominal)
}

fn developer_trace_ruler_label(
    sample: &DeveloperTraceSample,
    offset: usize,
    count: usize,
) -> String {
    if offset == 0 || offset + 1 == count || offset.is_multiple_of(10) {
        sample.sample_index.to_string()
    } else {
        "|".to_string()
    }
}

pub fn developer_trace_ruler_labels(samples: &[DeveloperTraceSample]) -> Vec<String> {
    samples
        .iter()
        .enumerate()
        .map(|(offset, sample)| developer_trace_ruler_label(sample, offset, samples.len()))
        .collect()
}

pub fn developer_trace_ruler_text(samples: &[DeveloperTraceSample]) -> String {
    developer_trace_ruler_labels(samples)
        .into_iter()
        .map(|label| {
            if label.chars().count() > 2 {
                label
                    .chars()
                    .rev()
                    .take(2)
                    .collect::<Vec<_>>()
                    .into_iter()
                    .rev()
                    .collect()
            } else {
                label
            }
        })
        .map(|label| format!("{label:<2}"))
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn developer_trace_ruler_width(samples: &[DeveloperTraceSample]) -> f32 {
    (samples.len().max(1) * 14) as f32
}

pub fn developer_trace_track_latest_signal(
    track: DeveloperTraceTrack,
    sample: Option<&DeveloperTraceSample>,
    trace: &DeveloperTraceSnapshot,
) -> String {
    let Some(sample) = sample else {
        return "--".to_string();
    };
    match track {
        DeveloperTraceTrack::Frame => format_ms(sample.frame_stats.work_ms()),
        DeveloperTraceTrack::Cpu => format_ms(cpu_ms(&sample.frame_stats)),
        DeveloperTraceTrack::GpuPresent => {
            format_ms(sample.frame_stats.gpu_present_seconds * 1000.0)
        }
        DeveloperTraceTrack::RenderPass => trace
            .render_passes
            .first()
            .map(|pass| format!("{} {}", pass.name, format_ns(pass.encode_ns)))
            .unwrap_or_else(|| "--".to_string()),
        DeveloperTraceTrack::Particles => {
            if sample.particle_dropped_count > 0 {
                format!("{} drops", sample.particle_dropped_count)
            } else if sample.particle_live_count > 0 {
                format!("{} live", sample.particle_live_count)
            } else {
                "--".to_string()
            }
        }
        DeveloperTraceTrack::Console => sample
            .console_severity
            .map(|severity| {
                match severity {
                    DeveloperDiagnosticSeverity::Nominal => "Nominal",
                    DeveloperDiagnosticSeverity::Info => "Info",
                    DeveloperDiagnosticSeverity::Warning => "Warning",
                    DeveloperDiagnosticSeverity::Critical => "Critical",
                }
                .to_string()
            })
            .unwrap_or_else(|| "--".to_string()),
    }
}

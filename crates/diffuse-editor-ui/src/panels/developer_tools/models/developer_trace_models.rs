//! Translation of
//! Editor/Sources/EditorUI/Panels/DeveloperTools/Models/DeveloperTraceModels.swift.

use diffuse_editor_core::diagnostics::issues::diagnostic_issue::{
    DeveloperDiagnosticIssue, DeveloperDiagnosticScope, DeveloperDiagnosticSeverity,
    DeveloperDiagnosticTarget,
};
use diffuse_editor_core::diagnostics::rendering::passes::DeveloperRenderPassInspection;
use diffuse_editor_core::state::editor_state::EditorFrameStats;

/// Swift's `String`-backed enums here carry display labels as their raw values.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DeveloperTraceMode {
    Live,
    Paused,
    Captured,
}

impl DeveloperTraceMode {
    pub const fn raw_value(self) -> &'static str {
        match self {
            DeveloperTraceMode::Live => "Live",
            DeveloperTraceMode::Paused => "Paused",
            DeveloperTraceMode::Captured => "Captured",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DeveloperTraceTrack {
    Frame,
    Cpu,
    GpuPresent,
    RenderPass,
    Particles,
    Console,
}

impl DeveloperTraceTrack {
    pub const ALL: [DeveloperTraceTrack; 6] = [
        DeveloperTraceTrack::Frame,
        DeveloperTraceTrack::Cpu,
        DeveloperTraceTrack::GpuPresent,
        DeveloperTraceTrack::RenderPass,
        DeveloperTraceTrack::Particles,
        DeveloperTraceTrack::Console,
    ];

    pub const fn raw_value(self) -> &'static str {
        match self {
            DeveloperTraceTrack::Frame => "Frame",
            DeveloperTraceTrack::Cpu => "CPU",
            DeveloperTraceTrack::GpuPresent => "GPU/Present",
            DeveloperTraceTrack::RenderPass => "Render Passes",
            DeveloperTraceTrack::Particles => "Particles",
            DeveloperTraceTrack::Console => "Console",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DeveloperTraceSeverityFilter {
    All,
    Problems,
    Critical,
    Warning,
}

impl DeveloperTraceSeverityFilter {
    pub const ALL: [DeveloperTraceSeverityFilter; 4] = [
        DeveloperTraceSeverityFilter::All,
        DeveloperTraceSeverityFilter::Problems,
        DeveloperTraceSeverityFilter::Critical,
        DeveloperTraceSeverityFilter::Warning,
    ];

    pub const fn raw_value(self) -> &'static str {
        match self {
            DeveloperTraceSeverityFilter::All => "All",
            DeveloperTraceSeverityFilter::Problems => "Problems",
            DeveloperTraceSeverityFilter::Critical => "Errors",
            DeveloperTraceSeverityFilter::Warning => "Warnings",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DeveloperTraceEventSortOrder {
    Newest,
    Severity,
    Track,
}

impl DeveloperTraceEventSortOrder {
    pub const ALL: [DeveloperTraceEventSortOrder; 3] = [
        DeveloperTraceEventSortOrder::Newest,
        DeveloperTraceEventSortOrder::Severity,
        DeveloperTraceEventSortOrder::Track,
    ];

    pub const fn raw_value(self) -> &'static str {
        match self {
            DeveloperTraceEventSortOrder::Newest => "Newest",
            DeveloperTraceEventSortOrder::Severity => "Severity",
            DeveloperTraceEventSortOrder::Track => "Track",
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeveloperTraceNavigationDirection {
    Previous,
    Next,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeveloperTraceSample {
    pub sample_index: u64,
    pub frame_index: u64,
    pub frame_stats: EditorFrameStats,
    pub particle_live_count: i64,
    pub particle_dropped_count: i64,
    pub console_severity: Option<DeveloperDiagnosticSeverity>,
    pub issue_ids: Vec<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeveloperTraceEvent {
    pub id: String,
    pub track: DeveloperTraceTrack,
    pub sample_index: u64,
    pub severity: DeveloperDiagnosticSeverity,
    pub scope: DeveloperDiagnosticScope,
    pub title: String,
    pub primary_signal: String,
    pub evidence: Vec<String>,
    pub recommendation: String,
    pub target: DeveloperDiagnosticTarget,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeveloperTraceSnapshot {
    pub mode: DeveloperTraceMode,
    pub samples: Vec<DeveloperTraceSample>,
    pub events: Vec<DeveloperTraceEvent>,
    pub render_passes: Vec<DeveloperRenderPassInspection>,
    pub issues: Vec<DeveloperDiagnosticIssue>,
}

impl DeveloperTraceSnapshot {
    pub fn with_mode(&self, next_mode: DeveloperTraceMode) -> DeveloperTraceSnapshot {
        let mut copy = self.clone();
        copy.mode = next_mode;
        copy
    }
}

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct DeveloperTraceInvestigationSummary {
    pub visible_event_count: i64,
    pub critical_count: i64,
    pub warning_count: i64,
    pub hot_sample_index: Option<u64>,
    pub hot_sample_event_count: i64,
    pub focus_event_id: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeveloperTraceSampleInvestigation {
    pub sample_index: u64,
    pub lead_event_id: Option<String>,
    pub event_count: i64,
    pub critical_count: i64,
    pub warning_count: i64,
    pub tracks: Vec<DeveloperTraceTrack>,
    pub drilldown_targets: Vec<DeveloperDiagnosticTarget>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum DeveloperTraceSampleContextPosition {
    Previous,
    Selected,
    Next,
}

impl DeveloperTraceSampleContextPosition {
    pub const fn raw_value(self) -> &'static str {
        match self {
            DeveloperTraceSampleContextPosition::Previous => "Previous",
            DeveloperTraceSampleContextPosition::Selected => "Selected",
            DeveloperTraceSampleContextPosition::Next => "Next",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeveloperTraceSampleContextRow {
    pub position: DeveloperTraceSampleContextPosition,
    pub sample_index: u64,
    pub work_ms: f64,
    pub work_delta_from_selected_ms: f64,
    pub event_count: i64,
    pub highest_severity: DeveloperDiagnosticSeverity,
}

#[derive(Clone, Debug, PartialEq)]
pub struct DeveloperTraceSampleContext {
    pub previous: Option<DeveloperTraceSampleContextRow>,
    pub selected: DeveloperTraceSampleContextRow,
    pub next: Option<DeveloperTraceSampleContextRow>,
}

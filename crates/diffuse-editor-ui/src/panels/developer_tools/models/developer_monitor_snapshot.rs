//! Translation of
//! Editor/Sources/EditorUI/Panels/DeveloperTools/Models/DeveloperMonitorSnapshot.swift.

use diffuse_editor_core::diagnostics::issues::diagnostic_issue::{
    DeveloperDiagnosticCounts, DeveloperDiagnosticIssue, DeveloperDiagnosticSeverity,
};

use super::developer_trace_models::DeveloperTraceTrack;

#[derive(Clone, Debug, PartialEq)]
pub struct DeveloperMonitorSnapshot {
    pub track: DeveloperTraceTrack,
    pub title: String,
    pub current_value: Option<f32>,
    pub current_label: String,
    pub range_label: String,
    pub sample_label: String,
    pub limit: Option<f32>,
    pub is_over_limit: bool,
    pub values: Vec<f32>,
}

pub fn make_developer_diagnostic_counts(
    issues: &[DeveloperDiagnosticIssue],
) -> DeveloperDiagnosticCounts {
    let count = |severity: DeveloperDiagnosticSeverity| {
        issues
            .iter()
            .filter(|issue| issue.severity == severity)
            .count() as i64
    };
    DeveloperDiagnosticCounts::new(
        count(DeveloperDiagnosticSeverity::Critical),
        count(DeveloperDiagnosticSeverity::Warning),
        count(DeveloperDiagnosticSeverity::Info),
        count(DeveloperDiagnosticSeverity::Nominal),
    )
}

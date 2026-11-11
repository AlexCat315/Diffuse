//! `Editor/Sources/EditorCore/Diagnostics/Issues/DiagnosticIssue.swift`.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DeveloperDiagnosticArea {
    Frame,
    Render,
    Particles,
    Console,
    State,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeveloperDiagnosticSeverity {
    #[serde(rename = "Nominal")]
    Nominal,
    #[serde(rename = "Info")]
    Info,
    #[serde(rename = "Warning")]
    Warning,
    #[serde(rename = "Critical")]
    Critical,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeveloperDiagnosticScope {
    #[serde(rename = "Frame")]
    Frame,
    #[serde(rename = "Render")]
    Render,
    #[serde(rename = "Particles")]
    Particles,
    #[serde(rename = "Console")]
    Console,
    #[serde(rename = "State")]
    State,
}

impl DeveloperDiagnosticScope {
    pub const fn raw_value(self) -> &'static str {
        match self {
            DeveloperDiagnosticScope::Frame => "Frame",
            DeveloperDiagnosticScope::Render => "Render",
            DeveloperDiagnosticScope::Particles => "Particles",
            DeveloperDiagnosticScope::Console => "Console",
            DeveloperDiagnosticScope::State => "State",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeveloperDiagnosticTarget {
    pub area: DeveloperDiagnosticArea,
    pub frame_sample_index: Option<u64>,
    pub label: String,
}

impl DeveloperDiagnosticTarget {
    pub fn new(
        area: DeveloperDiagnosticArea,
        frame_sample_index: Option<u64>,
        label: impl Into<String>,
    ) -> Self {
        DeveloperDiagnosticTarget {
            area,
            frame_sample_index,
            label: label.into(),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeveloperDiagnosticIssue {
    pub id: String,
    pub severity: DeveloperDiagnosticSeverity,
    pub scope: DeveloperDiagnosticScope,
    pub title: String,
    pub primary_signal: String,
    pub evidence: Vec<String>,
    pub recommendation: String,
    pub target: DeveloperDiagnosticTarget,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeveloperDiagnosticCounts {
    pub critical: i64,
    pub warning: i64,
    pub info: i64,
    pub nominal: i64,
}

impl DeveloperDiagnosticCounts {
    pub fn new(critical: i64, warning: i64, info: i64, nominal: i64) -> Self {
        DeveloperDiagnosticCounts {
            critical,
            warning,
            info,
            nominal,
        }
    }
}

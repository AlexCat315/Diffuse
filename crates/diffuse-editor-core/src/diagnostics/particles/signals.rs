//! `Editor/Sources/EditorCore/Diagnostics/Particles/Signals.swift`.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeveloperParticleDiagnosticSeverity {
    #[serde(rename = "Idle")]
    Idle,
    #[serde(rename = "Nominal")]
    Nominal,
    #[serde(rename = "Info")]
    Info,
    #[serde(rename = "Warning")]
    Warning,
    #[serde(rename = "Critical")]
    Critical,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeveloperParticleDiagnosticSummary {
    pub severity: DeveloperParticleDiagnosticSeverity,
    pub status: String,
    pub primary_signal: String,
    pub recommendation: String,
    pub details: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeveloperParticleEmitterLabel {
    #[serde(rename = "entityID")]
    pub entity_id: u64,
    pub name: String,
    pub kind: String,
    pub path: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeveloperParticleEmitterHotspot {
    #[serde(rename = "entityID")]
    pub entity_id: u64,
    pub severity: DeveloperParticleDiagnosticSeverity,
    pub reason: String,
    pub primary_signal: String,
    pub recommendation: String,
    pub details: Vec<String>,
    pub score: i64,
    pub live_particle_count: i64,
    pub requested_spawn_count: i64,
    pub spawned_particle_count: i64,
    pub dropped_spawn_count: i64,
    pub capacity_limited_spawn_count: i64,
    pub spawn_budget_limited_count: i64,
    pub event_dropped_spawn_count: i64,
    pub live_budget_text: String,
    pub spawn_budget_text: String,
}

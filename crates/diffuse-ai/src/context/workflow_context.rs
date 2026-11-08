//! Workflow contexts that shape Session's system prompt.

use std::fmt;

use diffuse_perception::SwiftDate;
use serde::de::Error as DeError;
use serde::ser::SerializeStruct;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::context::asset_workflow_context::AssetWorkflowContext;
use crate::context::workstation_context::WorkstationContext;

// MARK: - Game workflow

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaytestSummary {
    pub session_date: SwiftDate,
    pub player_count: i64,
    pub observations: Vec<String>,
}

impl PlaytestSummary {
    pub fn new(observations: Vec<String>) -> Self {
        Self {
            session_date: SwiftDate::now(),
            player_count: 1,
            observations,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum GameLevelPhase {
    #[serde(rename = "Blockout")]
    Blockout,
    #[serde(rename = "EncounterDesign")]
    EncounterDesign,
    #[serde(rename = "Polish")]
    Polish,
    #[serde(rename = "Balance")]
    Balance,
    #[serde(rename = "Ship")]
    Ship,
}

impl GameLevelPhase {
    pub fn as_str(self) -> &'static str {
        match self {
            GameLevelPhase::Blockout => "Blockout",
            GameLevelPhase::EncounterDesign => "EncounterDesign",
            GameLevelPhase::Polish => "Polish",
            GameLevelPhase::Balance => "Balance",
            GameLevelPhase::Ship => "Ship",
        }
    }
}

impl fmt::Display for GameLevelPhase {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GameplayIntent {
    pub genre: String,
    pub win_condition: String,
    pub player_count: i64,
    pub pacing: String,
}

impl GameplayIntent {
    pub fn new(genre: String, win_condition: String) -> Self {
        Self {
            genre,
            win_condition,
            player_count: 1,
            pacing: "exploration".to_string(),
        }
    }
}

/// Parameter descriptor for one script property.
///
/// `type` is a short human-readable description, e.g. "Float (m/s)" or "Bool".
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScriptParameterDescriptor {
    pub name: String,
    #[serde(rename = "type")]
    pub type_: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

impl ScriptParameterDescriptor {
    pub fn new(name: String, type_: String) -> Self {
        Self {
            name,
            type_,
            description: None,
        }
    }
}

/// Schema for one registered script, describing its public parameters.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScriptSchema {
    pub name: String,
    pub parameters: Vec<ScriptParameterDescriptor>,
}

impl ScriptSchema {
    pub fn new(name: String) -> Self {
        Self {
            name,
            parameters: Vec::new(),
        }
    }

    pub fn with_parameters(mut self, parameters: Vec<ScriptParameterDescriptor>) -> Self {
        self.parameters = parameters;
        self
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GameKnownConstraints {
    pub nav_mesh_baked: bool,
    pub performance_budget: String,
    /// Legacy name-only registry. Prefer `script_schemas` when parameter info is available.
    pub scripting_registry: Vec<String>,
    /// Full parameter schemas for registered scripts. When non-empty, used instead of
    /// `scripting_registry`.
    pub script_schemas: Vec<ScriptSchema>,
}

impl GameKnownConstraints {
    pub fn new() -> Self {
        Self {
            nav_mesh_baked: false,
            performance_budget: "console_high".to_string(),
            scripting_registry: Vec::new(),
            script_schemas: Vec::new(),
        }
    }
}

impl Default for GameKnownConstraints {
    fn default() -> Self {
        Self::new()
    }
}

/// Workflow context for interactive / game projects. Shapes Session's system
/// prompt so it reasons about player experience, encounter design, and level
/// pacing.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GameWorkflowContext {
    pub level_phase: GameLevelPhase,
    pub gameplay_intent: GameplayIntent,
    pub target_experience: String,
    pub known_constraints: GameKnownConstraints,
    pub playtest_observations: Vec<PlaytestSummary>,
}

impl GameWorkflowContext {
    pub fn new(gameplay_intent: GameplayIntent, target_experience: String) -> Self {
        Self {
            level_phase: GameLevelPhase::Blockout,
            gameplay_intent,
            target_experience,
            known_constraints: GameKnownConstraints::new(),
            playtest_observations: Vec::new(),
        }
    }

    pub(crate) fn system_prompt_section(&self) -> String {
        let mut lines = vec![
            "Workflow: game/interactive project".to_string(),
            format!("Level phase: {}", self.level_phase),
            format!(
                "Genre: {} | Win condition: {} | Pacing: {} | Players: {}",
                self.gameplay_intent.genre,
                self.gameplay_intent.win_condition,
                self.gameplay_intent.pacing,
                self.gameplay_intent.player_count
            ),
            format!("Target experience: {}", self.target_experience),
            format!(
                "Performance budget: {}",
                self.known_constraints.performance_budget
            ),
        ];
        if self.known_constraints.nav_mesh_baked {
            lines.push("NavMesh is baked — you can reason about traversability.".to_string());
        }
        if !self.known_constraints.script_schemas.is_empty() {
            let schema_lines = self
                .known_constraints
                .script_schemas
                .iter()
                .map(|schema| {
                    if schema.parameters.is_empty() {
                        return format!("  {}: (no parameters)", schema.name);
                    }
                    let parameters = schema
                        .parameters
                        .iter()
                        .map(|parameter| {
                            let mut text = format!("{}: {}", parameter.name, parameter.type_);
                            if let Some(description) = &parameter.description {
                                text.push_str(" — ");
                                text.push_str(description);
                            }
                            text
                        })
                        .collect::<Vec<_>>()
                        .join(", ");
                    format!("  {}: {}", schema.name, parameters)
                })
                .collect::<Vec<_>>()
                .join("\n");
            lines.push(format!(
                "Script schemas (use set_script_property to configure):\n{schema_lines}"
            ));
        } else if !self.known_constraints.scripting_registry.is_empty() {
            lines.push(format!(
                "Registered gameplay actions: {}",
                self.known_constraints.scripting_registry.join(", ")
            ));
        }
        if !self.playtest_observations.is_empty() {
            let start = self.playtest_observations.len().saturating_sub(3);
            let recent = self.playtest_observations[start..]
                .iter()
                .flat_map(|summary| summary.observations.iter())
                .cloned()
                .collect::<Vec<_>>();
            if !recent.is_empty() {
                lines.push(format!(
                    "Recent playtest observations: {}",
                    recent.join("; ")
                ));
            }
        }
        lines.join("\n")
    }
}

// MARK: - Film workflow

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum FilmNarrativePhase {
    #[serde(rename = "blocking")]
    Blocking,
    #[serde(rename = "performance")]
    Performance,
    #[serde(rename = "camera_language")]
    CameraLanguage,
    #[serde(rename = "lighting")]
    Lighting,
    #[serde(rename = "review")]
    Review,
}

impl FilmNarrativePhase {
    pub fn as_str(self) -> &'static str {
        match self {
            FilmNarrativePhase::Blocking => "blocking",
            FilmNarrativePhase::Performance => "performance",
            FilmNarrativePhase::CameraLanguage => "camera_language",
            FilmNarrativePhase::Lighting => "lighting",
            FilmNarrativePhase::Review => "review",
        }
    }

    /// Approval policy constraint for this phase.
    fn requires_strict_approval(self) -> bool {
        self == FilmNarrativePhase::Review
    }
}

impl fmt::Display for FilmNarrativePhase {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(self.as_str())
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ReferenceAnchor {
    pub uri: String,
    pub semantic_summary: String,
    pub added_at: SwiftDate,
}

impl ReferenceAnchor {
    pub fn new(uri: String, semantic_summary: String) -> Self {
        Self {
            uri,
            semantic_summary,
            added_at: SwiftDate::now(),
        }
    }
}

/// Workflow context for cinematic / film projects. Shapes Session's reasoning
/// around narrative intent, shot language, and phase-appropriate approval
/// policies.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FilmWorkflowContext {
    #[serde(rename = "activeSequenceID")]
    pub active_sequence_id: String,
    #[serde(rename = "activeShotID", skip_serializing_if = "Option::is_none")]
    pub active_shot_id: Option<String>,
    pub narrative_phase: FilmNarrativePhase,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub director_intent: Option<String>,
    pub reference_anchors: Vec<ReferenceAnchor>,
    #[serde(rename = "lockedShotIDs")]
    pub locked_shot_ids: Vec<String>,
}

impl FilmWorkflowContext {
    pub fn new(active_sequence_id: String) -> Self {
        Self {
            active_sequence_id,
            active_shot_id: None,
            narrative_phase: FilmNarrativePhase::Blocking,
            director_intent: None,
            reference_anchors: Vec::new(),
            locked_shot_ids: Vec::new(),
        }
    }

    pub(crate) fn system_prompt_section(&self) -> String {
        let mut lines = vec![
            "Workflow: cinematic / film project".to_string(),
            format!("Narrative phase: {}", self.narrative_phase),
            format!("Active sequence: {}", self.active_sequence_id),
        ];
        if let Some(shot) = &self.active_shot_id {
            lines.push(format!("Active shot: {shot}"));
        }
        if let Some(intent) = &self.director_intent
            && !intent.is_empty()
        {
            lines.push(format!("Director intent: {intent}"));
        }
        if !self.locked_shot_ids.is_empty() {
            lines.push(format!(
                "Locked shots (do not modify): {}",
                self.locked_shot_ids.join(", ")
            ));
        }
        if self.narrative_phase.requires_strict_approval() {
            lines.push(
                "Review phase: all proposals require explicit approval — never use automatic mode."
                    .to_string(),
            );
        }
        if !self.reference_anchors.is_empty() {
            let summaries = self
                .reference_anchors
                .iter()
                .map(|anchor| format!("[{}: {}]", anchor.uri, anchor.semantic_summary))
                .collect::<Vec<_>>()
                .join("; ");
            lines.push(format!("Reference anchors: {summaries}"));
        }
        lines.join("\n")
    }
}

// MARK: - Unified WorkflowContext

#[derive(Clone, Debug, PartialEq)]
pub enum WorkflowContext {
    Workstation(WorkstationContext),
    Asset(AssetWorkflowContext),
    Game(GameWorkflowContext),
    Film(FilmWorkflowContext),
}

impl WorkflowContext {
    pub(crate) fn system_prompt_section(&self) -> String {
        match self {
            WorkflowContext::Workstation(context) => context.system_prompt_section(),
            WorkflowContext::Asset(context) => context.system_prompt_section(),
            WorkflowContext::Game(context) => context.system_prompt_section(),
            WorkflowContext::Film(context) => context.system_prompt_section(),
        }
    }
}

#[derive(Deserialize)]
struct WorkflowContextWire {
    kind: String,
    payload: serde_json::Value,
}

impl Serialize for WorkflowContext {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut state = serializer.serialize_struct("WorkflowContext", 2)?;
        match self {
            WorkflowContext::Workstation(context) => {
                state.serialize_field("kind", "workstation")?;
                state.serialize_field("payload", context)?;
            }
            WorkflowContext::Asset(context) => {
                state.serialize_field("kind", "asset")?;
                state.serialize_field("payload", context)?;
            }
            WorkflowContext::Game(context) => {
                state.serialize_field("kind", "game")?;
                state.serialize_field("payload", context)?;
            }
            WorkflowContext::Film(context) => {
                state.serialize_field("kind", "film")?;
                state.serialize_field("payload", context)?;
            }
        }
        state.end()
    }
}

impl<'de> Deserialize<'de> for WorkflowContext {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let wire = WorkflowContextWire::deserialize(deserializer)?;
        match wire.kind.as_str() {
            "workstation" => serde_json::from_value(wire.payload)
                .map(WorkflowContext::Workstation)
                .map_err(<D::Error as DeError>::custom),
            "asset" => serde_json::from_value(wire.payload)
                .map(WorkflowContext::Asset)
                .map_err(<D::Error as DeError>::custom),
            "game" => serde_json::from_value(wire.payload)
                .map(WorkflowContext::Game)
                .map_err(<D::Error as DeError>::custom),
            "film" => serde_json::from_value(wire.payload)
                .map(WorkflowContext::Film)
                .map_err(<D::Error as DeError>::custom),
            other => Err(<D::Error as DeError>::custom(format!(
                "unknown WorkflowContext kind '{other}'"
            ))),
        }
    }
}

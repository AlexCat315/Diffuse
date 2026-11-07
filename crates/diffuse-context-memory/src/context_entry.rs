//! `ContextEntry.swift` — one unit of long-term AI context memory.

use std::collections::BTreeMap;
use std::time::{SystemTime, UNIX_EPOCH};

use diffuse_kernel::codable::new_uuid;
use serde::ser::SerializeMap;
use serde::{Deserialize, Serialize, Serializer};

/// Closed set of context memory entry kinds. New kinds must be added here (not
/// dynamically registered) so reducers stay exhaustive and replay-deterministic.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntryKind {
    /// A summarized edit applied to a scene entity.
    EntityEdit,
    /// A behavioral preference inferred from user corrections.
    UserPreference,
    /// The active workflow context at a point in time.
    WorkflowContext,
    /// A semantic annotation attached to a scene entity or asset.
    SceneAnnotation,
    /// A high-level session summary produced at session close.
    SessionSummary,
    /// A tracked issue or outstanding question.
    IssueTracked,
}

impl EntryKind {
    /// Swift's `CaseIterable.allCases`.
    pub const ALL: [EntryKind; 6] = [
        EntryKind::EntityEdit,
        EntryKind::UserPreference,
        EntryKind::WorkflowContext,
        EntryKind::SceneAnnotation,
        EntryKind::SessionSummary,
        EntryKind::IssueTracked,
    ];

    /// Swift's `rawValue`.
    pub const fn as_str(self) -> &'static str {
        match self {
            EntryKind::EntityEdit => "entity_edit",
            EntryKind::UserPreference => "user_preference",
            EntryKind::WorkflowContext => "workflow_context",
            EntryKind::SceneAnnotation => "scene_annotation",
            EntryKind::SessionSummary => "session_summary",
            EntryKind::IssueTracked => "issue_tracked",
        }
    }
}

/// A single unit of long-term AI context memory.
///
/// All payload values are LLM-safe strings or numbers — no vectors, embeddings,
/// spectral hashes or raw image bytes. Reducers must enforce this invariant.
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct ContextEntry {
    /// Stable UUID string.
    pub id: String,
    pub kind: EntryKind,
    /// The primary subject (`scene:42`, an asset URI, or `session`).
    pub subject: String,
    /// LLM-safe key-value payload.
    pub payload: BTreeMap<String, String>,
    /// Importance score in `[0, 1]`, used for eviction and prompt-budget ranking.
    pub importance: f64,
    /// World revision when this entry was last written.
    pub revision: u64,
    /// Wall-clock timestamp (seconds since the Unix epoch) of the last write.
    pub timestamp: f64,
}

/// Swift's `JSONEncoder.outputFormatting = [.sortedKeys]` sorts *every* key,
/// including the struct's own fields. `serde` emits struct fields in declaration
/// order, so the wire form is written by hand with alphabetical keys.
impl Serialize for ContextEntry {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let mut map = serializer.serialize_map(Some(7))?;
        map.serialize_entry("id", &self.id)?;
        map.serialize_entry("importance", &self.importance)?;
        map.serialize_entry("kind", &self.kind)?;
        map.serialize_entry("payload", &self.payload)?;
        map.serialize_entry("revision", &self.revision)?;
        map.serialize_entry("subject", &self.subject)?;
        map.serialize_entry("timestamp", &self.timestamp)?;
        map.end()
    }
}

impl ContextEntry {
    /// Swift's `init(id:kind:subject:payload:importance:revision:timestamp:)`.
    /// All arguments except `kind`, `subject` and `payload` had defaults; the
    /// builders below reproduce those defaults explicitly.
    pub fn new(
        kind: EntryKind,
        subject: impl Into<String>,
        payload: BTreeMap<String, String>,
    ) -> Self {
        ContextEntry {
            id: new_uuid(),
            kind,
            subject: subject.into(),
            payload,
            importance: 0.5,
            revision: 0,
            timestamp: now_seconds(),
        }
    }

    pub fn with_id(mut self, id: impl Into<String>) -> Self {
        self.id = id.into();
        self
    }

    pub fn with_importance(mut self, importance: f64) -> Self {
        // Swift `max(0, min(1, importance))`; `clamp` keeps NaN as NaN.
        self.importance = importance.clamp(0.0, 1.0);
        self
    }

    pub fn with_revision(mut self, revision: u64) -> Self {
        self.revision = revision;
        self
    }

    pub fn with_timestamp(mut self, timestamp: f64) -> Self {
        self.timestamp = timestamp;
        self
    }
}

/// Swift `Date()` encoded by `JSONEncoder` is a `Double` of Unix epoch seconds.
pub fn now_seconds() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or(0.0)
}

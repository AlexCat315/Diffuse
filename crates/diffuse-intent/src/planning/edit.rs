//! The `Edit` record: one applied world change.
//!
//! Every successful transaction apply produces exactly one `Edit`. The edit log at
//! `<project>/.cove/edit_log.jsonl` is the append-only stream of these records, which
//! makes them both audit history and training data — so the field set and the encoded
//! key names are part of the persisted format (§5.4).

use diffuse_capability::support::swift_date::SwiftDate;
use serde::{Deserialize, Serialize};
pub use uuid_free::uuid_string;

/// Alias matching the workspace-wide `new_uuid` naming.
#[inline]
pub fn new_uuid() -> String {
    uuid_string()
}

/// The world's revision before or after an edit.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorldRevisionSnapshot {
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub scene_revision: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub sequence_revision_id: Option<String>,
}

impl WorldRevisionSnapshot {
    pub fn new(scene_revision: Option<u64>, sequence_revision_id: Option<String>) -> Self {
        WorldRevisionSnapshot {
            scene_revision,
            sequence_revision_id,
        }
    }
}

/// Who authored an edit.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum EditAuthorKind {
    Human,
    Ai,
    System,
}

/// Records that an AI proposal was partially accepted.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CorrectionDelta {
    pub original_proposal_id: String,
    pub was_partial_accept: bool,
}

impl CorrectionDelta {
    pub fn new(original_proposal_id: impl Into<String>, was_partial_accept: bool) -> Self {
        CorrectionDelta {
            original_proposal_id: original_proposal_id.into(),
            was_partial_accept,
        }
    }
}

/// Where an edit came from.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditProvenance {
    pub author_kind: EditAuthorKind,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub session_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub proposal_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub correction_delta: Option<CorrectionDelta>,
    /// Swift's `Date`, i.e. seconds since 2001-01-01.
    pub timestamp: SwiftDate,
}

impl EditProvenance {
    pub fn new(author_kind: EditAuthorKind) -> Self {
        EditProvenance {
            author_kind,
            session_id: None,
            proposal_id: None,
            correction_delta: None,
            timestamp: SwiftDate::now(),
        }
    }
}

/// One applied world change.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Edit {
    pub id: String,
    pub transaction_id: String,
    pub summary: String,
    pub mutation_summaries: Vec<String>,
    pub changed_domains: Vec<String>,
    pub provenance: EditProvenance,
    pub revision_before: WorldRevisionSnapshot,
    pub revision_after: WorldRevisionSnapshot,
}

impl Edit {
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        id: impl Into<String>,
        transaction_id: impl Into<String>,
        summary: impl Into<String>,
        mutation_summaries: Vec<String>,
        changed_domains: Vec<String>,
        provenance: EditProvenance,
        revision_before: WorldRevisionSnapshot,
        revision_after: WorldRevisionSnapshot,
    ) -> Self {
        Edit {
            id: id.into(),
            transaction_id: transaction_id.into(),
            summary: summary.into(),
            mutation_summaries,
            changed_domains,
            provenance,
            revision_before,
            revision_after,
        }
    }

    /// A fresh id: Swift's `UUID().uuidString` default.
    pub fn with_default_id(
        transaction_id: impl Into<String>,
        summary: impl Into<String>,
        mutation_summaries: Vec<String>,
        changed_domains: Vec<String>,
        provenance: EditProvenance,
        revision_before: WorldRevisionSnapshot,
        revision_after: WorldRevisionSnapshot,
    ) -> Self {
        Edit::new(
            uuid_string(),
            transaction_id,
            summary,
            mutation_summaries,
            changed_domains,
            provenance,
            revision_before,
            revision_after,
        )
    }
}

/// A random v4 UUID, uppercase, 36 characters — Swift's `UUID().uuidString`.
///
/// Kept in this crate rather than reached for from elsewhere so the persisted `id`
/// fields need no new dependency; the shape is asserted by a test below.
pub mod uuid_free {
    use std::sync::atomic::{AtomicU64, Ordering};

    /// A random v4 UUID, uppercase, 36 characters (8-4-4-4-12).
    pub fn uuid_string() -> String {
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|duration| duration.as_nanos() as u64)
            .unwrap_or(0);
        let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
        let mixed = nanos ^ counter.wrapping_mul(0x9E37_79B9_7F4A_7C15);
        let time_low = (mixed & 0xFFFF_FFFF) as u32;
        let time_mid = ((mixed >> 32) & 0xFFFF) as u16;
        let time_hi = (((mixed >> 48) & 0x0FFF) as u16) | 0x4000;
        let clock = ((counter & 0x3FFF) as u16) | 0x8000;
        let node: u64 = (mixed >> 8) & 0x0000_FFFF_FFFF_FFFF;
        format!("{time_low:08X}-{time_mid:04X}-{time_hi:04X}-{clock:04X}-{node:012X}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_default_id_is_a_swift_shaped_uuid() {
        let id = uuid_string();
        assert_eq!(id.len(), 36);
        let groups: Vec<usize> = id.split('-').map(str::len).collect();
        assert_eq!(groups, vec![8, 4, 4, 4, 12]);
        assert_eq!(id, id.to_uppercase());
    }

    #[test]
    fn optional_provenance_fields_are_omitted_when_absent() {
        let provenance = EditProvenance::new(EditAuthorKind::Human);
        let json = serde_json::to_string(&provenance).expect("serialize");
        assert!(
            !json.contains("sessionId"),
            "absent sessionId must be omitted: {json}"
        );
        assert!(!json.contains("proposalId"));
        assert!(!json.contains("correctionDelta"));
        assert!(json.contains("\"authorKind\":\"human\""));
    }

    #[test]
    fn the_timestamp_encodes_as_swift_seconds_since_2001() {
        let provenance = EditProvenance {
            timestamp: SwiftDate(0.0),
            ..EditProvenance::new(EditAuthorKind::System)
        };
        let json = serde_json::to_string(&provenance).expect("serialize");
        assert!(json.contains("\"timestamp\":0.0"), "got {json}");
    }

    #[test]
    fn an_edit_round_trips() {
        let provenance = EditProvenance::new(EditAuthorKind::Ai);
        let edit = Edit::new(
            "edit-1",
            "tx-1",
            "move cube",
            vec!["translation".to_string()],
            vec!["scene".to_string()],
            provenance,
            WorldRevisionSnapshot::new(Some(1), None),
            WorldRevisionSnapshot::new(Some(2), None),
        );
        let json = serde_json::to_string(&edit).expect("serialize");
        let restored: Edit = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(restored, edit);
    }

    #[test]
    fn a_revision_snapshot_omits_absent_fields() {
        let snapshot = WorldRevisionSnapshot::new(None, None);
        let json = serde_json::to_string(&snapshot).expect("serialize");
        assert_eq!(json, "{}");
    }
}

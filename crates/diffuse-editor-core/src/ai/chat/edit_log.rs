//! `Editor/Sources/EditorCore/AI/Chat/EditLog.swift` — append-only JSONL log of
//! every applied `Edit`, written to `<project>/.cove/edit_log.jsonl`.
//!
//! Swift configured its encoder with `dateEncodingStrategy = .iso8601`, so the
//! record's `timestamp` lands on disk as an ISO 8601 string with second
//! precision even though `Edit` itself carries a `Date`. The line wrapper below
//! reproduces that encoding (including Swift's `sessionID` / `proposalID` /
//! `sequenceRevisionID` spelling) instead of reusing `Edit`'s own `Serialize`.

use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use diffuse_capability::support::swift_date::{SWIFT_DATE_REFERENCE_UNIX_SECONDS, SwiftDate};
use diffuse_intent::planning::edit::{Edit, EditAuthorKind, EditProvenance, WorldRevisionSnapshot};
use serde::{Serialize, Serializer};

/// Failure while encoding or appending one log line.
#[derive(Debug, thiserror::Error)]
pub enum EditLogError {
    #[error("the edit could not be encoded: {0}")]
    Encode(#[from] serde_json::Error),
    #[error("the edit log could not be written: {0}")]
    Io(#[from] std::io::Error),
}

pub struct EditLog {
    file_url: PathBuf,
    lock: Mutex<()>,
}

impl EditLog {
    pub fn new(project_directory: impl AsRef<Path>) -> Self {
        EditLog {
            file_url: project_directory
                .as_ref()
                .join(".cove")
                .join("edit_log.jsonl"),
            lock: Mutex::new(()),
        }
    }

    pub fn append(&self, edit: &Edit) -> Result<(), EditLogError> {
        let mut line = serde_json::to_vec(&EditLine::from(edit))?;
        line.push(b'\n');
        let _guard = self
            .lock
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let parent = self.file_url.parent().unwrap_or_else(|| Path::new("."));
        fs::create_dir_all(parent)?;
        if self.file_url.exists() {
            let mut handle = OpenOptions::new().append(true).open(&self.file_url)?;
            handle.write_all(&line)?;
        } else {
            cove_system::files::atomic_write(
                &self.file_url,
                &line,
                cove_system::files::Access::Inherit,
            )?;
        }
        Ok(())
    }
}

/// `Edit` as the log writes it: Swift's synthesized key order and an ISO 8601
/// timestamp.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct EditLine<'a> {
    id: &'a str,
    transaction_id: &'a str,
    summary: &'a str,
    mutation_summaries: &'a [String],
    changed_domains: &'a [String],
    provenance: ProvenanceLine<'a>,
    revision_before: RevisionLine<'a>,
    revision_after: RevisionLine<'a>,
}

impl<'a> From<&'a Edit> for EditLine<'a> {
    fn from(edit: &'a Edit) -> Self {
        EditLine {
            id: &edit.id,
            transaction_id: &edit.transaction_id,
            summary: &edit.summary,
            mutation_summaries: &edit.mutation_summaries,
            changed_domains: &edit.changed_domains,
            provenance: ProvenanceLine::from(&edit.provenance),
            revision_before: RevisionLine::from(&edit.revision_before),
            revision_after: RevisionLine::from(&edit.revision_after),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ProvenanceLine<'a> {
    author_kind: &'a EditAuthorKind,
    #[serde(rename = "sessionID", skip_serializing_if = "Option::is_none")]
    session_id: Option<&'a str>,
    #[serde(rename = "proposalID", skip_serializing_if = "Option::is_none")]
    proposal_id: Option<&'a str>,
    #[serde(skip_serializing_if = "Option::is_none")]
    correction_delta: Option<CorrectionDeltaLine<'a>>,
    timestamp: Iso8601,
}

impl<'a> From<&'a EditProvenance> for ProvenanceLine<'a> {
    fn from(provenance: &'a EditProvenance) -> Self {
        ProvenanceLine {
            author_kind: &provenance.author_kind,
            session_id: provenance.session_id.as_deref(),
            proposal_id: provenance.proposal_id.as_deref(),
            correction_delta: provenance.correction_delta.as_ref().map(|delta| {
                CorrectionDeltaLine {
                    original_proposal_id: &delta.original_proposal_id,
                    was_partial_accept: delta.was_partial_accept,
                }
            }),
            timestamp: Iso8601(provenance.timestamp),
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CorrectionDeltaLine<'a> {
    #[serde(rename = "originalProposalID")]
    original_proposal_id: &'a str,
    was_partial_accept: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct RevisionLine<'a> {
    #[serde(skip_serializing_if = "Option::is_none")]
    scene_revision: Option<u64>,
    #[serde(rename = "sequenceRevisionID", skip_serializing_if = "Option::is_none")]
    sequence_revision_id: Option<&'a str>,
}

impl<'a> From<&'a WorldRevisionSnapshot> for RevisionLine<'a> {
    fn from(revision: &'a WorldRevisionSnapshot) -> Self {
        RevisionLine {
            scene_revision: revision.scene_revision,
            sequence_revision_id: revision.sequence_revision_id.as_deref(),
        }
    }
}

/// Swift `Date` rendered by `JSONEncoder` with `.iso8601`: UTC, no fractional
/// seconds.
struct Iso8601(SwiftDate);

impl Serialize for Iso8601 {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let unix_seconds = self.0.0 + SWIFT_DATE_REFERENCE_UNIX_SECONDS as f64;
        serializer.serialize_str(&cove_logging::iso8601(unix_seconds.floor()).replace(".000Z", "Z"))
    }
}

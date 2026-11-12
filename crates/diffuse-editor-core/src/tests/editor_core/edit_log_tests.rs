//! Ported from `Editor/Tests/EditorCoreTests/EditLogTests.swift`.

use std::path::{Path, PathBuf};

use diffuse_capability::support::swift_date::{SWIFT_DATE_REFERENCE_UNIX_SECONDS, SwiftDate};
use diffuse_intent::planning::edit::{Edit, EditAuthorKind, EditProvenance, WorldRevisionSnapshot};

use crate::ai::chat::edit_log::EditLog;

fn temporary_root(prefix: &str) -> PathBuf {
    std::env::temp_dir().join(format!("{prefix}-{}", diffuse_kernel::codable::new_uuid()))
}

fn remove_temporary_root(url: &Path) {
    if url.is_dir() {
        let _ = std::fs::remove_dir_all(url);
    } else {
        let _ = std::fs::remove_file(url);
    }
}

fn make_edit(id: &str, revision: u64) -> Edit {
    Edit::new(
        id,
        format!("transaction-{id}"),
        id,
        vec!["rename".to_string()],
        vec!["scene".to_string()],
        EditProvenance {
            author_kind: EditAuthorKind::Ai,
            session_id: None,
            proposal_id: None,
            correction_delta: None,
            timestamp: SwiftDate(revision as f64 - SWIFT_DATE_REFERENCE_UNIX_SECONDS as f64),
        },
        WorldRevisionSnapshot::new(Some(revision - 1), None),
        WorldRevisionSnapshot::new(Some(revision), None),
    )
}

/// Appending creates `.cove/`, writes one JSONL record per edit, and keeps the
/// append order; each record decodes like Swift's `.iso8601` date strategy.
#[test]
fn append_creates_parent_and_preserves_jsonl_order() {
    let project = temporary_root("cove-edit-log");
    std::fs::create_dir_all(&project).expect("temporary project");
    let log = EditLog::new(&project);

    log.append(&make_edit("first", 1)).expect("append first");
    log.append(&make_edit("second", 2)).expect("append second");

    let log_url = project.join(".cove").join("edit_log.jsonl");
    let contents = std::fs::read_to_string(&log_url).expect("read edit log");
    let edits: Vec<serde_json::Value> = contents
        .split('\n')
        .filter(|line| !line.is_empty())
        .map(|line| serde_json::from_str(line).expect("decode edit line"))
        .collect();
    let ids: Vec<&str> = edits
        .iter()
        .map(|edit| edit["id"].as_str().expect("edit id"))
        .collect();
    assert_eq!(ids, ["first", "second"]);
    assert_eq!(
        edits[0]["provenance"]["timestamp"].as_str(),
        Some("1970-01-01T00:00:01Z")
    );

    remove_temporary_root(&project);
}

/// A project path occupied by a regular file cannot host the JSONL log, and the
/// failure surfaces to the caller instead of being swallowed.
#[test]
fn append_surfaces_unwritable_project_layout() {
    let project = temporary_root("cove-edit-log-file");
    std::fs::write(&project, b"not-a-directory").expect("blocking file");
    let log = EditLog::new(&project);

    assert!(log.append(&make_edit("blocked", 1)).is_err());

    remove_temporary_root(&project);
}

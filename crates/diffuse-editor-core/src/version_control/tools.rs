//! Translation of `Editor/Sources/EditorCore/VersionControl/Tools.swift`.
//!
//! The `vcs_*` project tools, over the same model the Source Control panel
//! shows.

use std::collections::BTreeSet;

use diffuse_capability::support::swift_date::{
    SWIFT_DATE_REFERENCE_UNIX_SECONDS, SwiftDate,
};
use serde_json::{Value, json};
use unicode_segmentation::UnicodeSegmentation;

use crate::ai::editor_project_tools::EditorProjectToolError;
use crate::application::editor_application::EditorApplication;
use crate::version_control::backend::VersionControlError;
use crate::version_control::model::{
    VersionControlAvailability, VersionControlChange, VersionControlRevision,
};

impl EditorApplication {
    pub(crate) fn execute_version_control_tool(
        &self,
        name: &str,
        arguments: &serde_json::Map<String, Value>,
    ) -> Result<Option<Value>, EditorProjectToolError> {
        if !name.starts_with("vcs_") {
            return Ok(None);
        }
        let version_control = &self.workstation.version_control;
        version_control.refresh();
        let snapshot = version_control.snapshot();
        let Some(repository) = snapshot.repository() else {
            if let VersionControlAvailability::ToolMissing(system) = &snapshot.availability {
                return Err(EditorProjectToolError::new(
                    VersionControlError::ToolMissing(system.clone()).error_description(),
                ));
            }
            return Err(EditorProjectToolError::new(
                "This project is not in a Git or Lore working tree.",
            ));
        };
        match name {
            "vcs_status" => {
                let tracking = &snapshot.status.tracking;
                let changes: Vec<Value> = snapshot
                    .status
                    .changes
                    .iter()
                    .map(|change| {
                        json!({
                            "path": change.path,
                            "state": change.state.raw_value(),
                            "staged": change.is_staged,
                            "original_path": optional_string(change.original_path.as_deref()),
                        })
                    })
                    .collect();
                Ok(Some(json!({
                    "system": repository.system.raw_value(),
                    "branch": optional_string(tracking.branch.as_deref()),
                    "upstream": optional_string(tracking.upstream.as_deref()),
                    "ahead": tracking.ahead,
                    "behind": tracking.behind,
                    "changes": changes,
                })))
            }
            "vcs_diff" => {
                let path = arguments.get("path").and_then(Value::as_str);
                let changes: Vec<&VersionControlChange> = snapshot
                    .status
                    .changes
                    .iter()
                    .filter(|change| path.is_none() || Some(change.path.as_str()) == path)
                    .collect();
                if changes.is_empty() {
                    return Err(EditorProjectToolError::new(match path {
                        Some(path) => format!(
                            "No change at {path}. Read vcs_status for changed paths."
                        ),
                        None => "There are no changes.".to_string(),
                    }));
                }
                let mut budget: i64 = 60_000;
                let mut diffs: Vec<Value> = Vec::new();
                for change in changes {
                    if budget <= 0 {
                        diffs.push(json!({ "path": change.path, "truncated": true }));
                        continue;
                    }
                    let text = version_control.diff(change);
                    // `String.prefix` and `String.count` are Character counts.
                    let diff: String = text.graphemes(true).take(budget as usize).collect();
                    budget -= diff.graphemes(true).count() as i64;
                    diffs.push(json!({
                        "path": change.path,
                        "staged": change.is_staged,
                        "diff": diff,
                    }));
                }
                Ok(Some(json!({ "diffs": diffs })))
            }
            "vcs_log" => {
                let limit = arguments
                    .get("limit")
                    .and_then(Value::as_i64)
                    .unwrap_or(20);
                let revisions: Vec<Value> = snapshot
                    .history
                    .iter()
                    .take(limit.max(0) as usize)
                    .map(revision_value)
                    .collect();
                Ok(Some(json!({ "revisions": revisions })))
            }
            "vcs_commit" => {
                let paths: BTreeSet<String> = arguments
                    .get("paths")
                    .and_then(Value::as_array)
                    .map(|values| {
                        values
                            .iter()
                            .filter_map(Value::as_str)
                            .map(str::to_string)
                            .collect()
                    })
                    .unwrap_or_default();
                if let Some(unknown) = paths.iter().find(|path| {
                    !snapshot
                        .status
                        .changes
                        .iter()
                        .any(|change| &change.path == *path)
                }) {
                    return Err(EditorProjectToolError::new(format!(
                        "{unknown} has no change. Read vcs_status for changed paths."
                    )));
                }
                if !paths.is_empty() {
                    let changes: Vec<VersionControlChange> = snapshot
                        .unstaged()
                        .into_iter()
                        .filter(|change| paths.contains(&change.path))
                        .cloned()
                        .collect();
                    version_control.stage(&changes);
                    if let Some(error) = version_control.snapshot().error {
                        return Err(EditorProjectToolError::new(error));
                    }
                }
                self.commit(
                    arguments
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or(""),
                )
            }
            _ => Ok(None),
        }
    }

    fn commit(&self, message: &str) -> Result<Option<Value>, EditorProjectToolError> {
        let version_control = &self.workstation.version_control;
        if !version_control.commit(message) {
            return Err(EditorProjectToolError::new(
                version_control
                    .snapshot()
                    .error
                    .unwrap_or_else(|| "Commit failed.".to_string()),
            ));
        }
        let revision = version_control
            .snapshot()
            .history
            .first()
            .map(|revision| Value::String(revision.id.clone()))
            .unwrap_or(Value::Null);
        Ok(Some(json!({ "ok": true, "revision": revision })))
    }
}

fn revision_value(revision: &VersionControlRevision) -> Value {
    json!({
        "id": revision.id,
        "summary": revision.summary,
        "author": optional_string(revision.author.as_deref()),
        "date": revision.date.map_or(Value::Null, |date| Value::String(iso8601(date))),
    })
}

fn optional_string(value: Option<&str>) -> Value {
    value.map_or(Value::Null, |value| Value::String(value.to_string()))
}

/// `ISO8601DateFormatter().string(from:)`: UTC, second precision.
fn iso8601(date: SwiftDate) -> String {
    let unix_seconds = date.0 + SWIFT_DATE_REFERENCE_UNIX_SECONDS as f64;
    cove_logging::iso8601(unix_seconds.floor()).replace(".000Z", "Z")
}

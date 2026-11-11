//! `Editor/Sources/EditorCore/VersionControl/Operations.swift`.

use std::collections::BTreeSet;

use serde::Deserialize;
use serde::de::DeserializeOwned;

use diffuse_capability::support::swift_date::{SWIFT_DATE_REFERENCE_UNIX_SECONDS, SwiftDate};

use crate::contributions::host::{StepError, StepPlugin};
use crate::contributions::steps::StepOutcome;
use crate::version_control::backend::{VersionControlBackend, VersionControlError};
use crate::version_control::model::{
    VersionControlBranch, VersionControlChange, VersionControlFileState, VersionControlRepository,
    VersionControlRevision, VersionControlStatus, VersionControlTracking,
};

/// A version control backend whose every command comes from its plugin.
pub struct PluginBackend {
    pub repository: VersionControlRepository,
    pub plugin: StepPlugin,
}

impl PluginBackend {
    fn perform(&self, operation: serde_json::Value) -> Result<StepOutcome, VersionControlError> {
        self.plugin
            .perform(&operation, None, StepPlugin::WINDOW, None, None)
            .map_err(VersionControlError::from)
    }

    fn result<T: DeserializeOwned>(
        &self,
        operation: serde_json::Value,
    ) -> Result<T, VersionControlError> {
        let op = operation
            .get("op")
            .and_then(|value| value.as_str())
            .unwrap_or("")
            .to_string();
        match self.perform(operation)? {
            StepOutcome::Result(data) => serde_json::from_slice(&data).map_err(|error| {
                VersionControlError::Unsupported(format!(
                    "The {} plugin returned an unreadable result: {error}",
                    self.plugin.provider.title
                ))
            }),
            StepOutcome::Output(_) => Err(VersionControlError::Unsupported(format!(
                "The {} plugin returned text for {op}.",
                self.plugin.provider.title
            ))),
        }
    }

    fn wire(change: &VersionControlChange) -> serde_json::Value {
        let mut object = serde_json::Map::new();
        object.insert("path".to_string(), serde_json::json!(change.path));
        object.insert(
            "state".to_string(),
            serde_json::json!(change.state.raw_value()),
        );
        object.insert("staged".to_string(), serde_json::json!(change.is_staged));
        if let Some(original) = &change.original_path {
            object.insert("originalPath".to_string(), serde_json::json!(original));
        }
        serde_json::Value::Object(object)
    }
}

impl VersionControlBackend for PluginBackend {
    fn repository(&self) -> &VersionControlRepository {
        &self.repository
    }

    fn status(&self) -> Result<VersionControlStatus, VersionControlError> {
        let wire: StatusWire = self.result(serde_json::json!({ "op": "status" }))?;
        Ok(wire.model())
    }

    fn history(&self, limit: i64) -> Result<Vec<VersionControlRevision>, VersionControlError> {
        let wire: Vec<RevisionWire> =
            self.result(serde_json::json!({ "op": "history", "limit": limit }))?;
        Ok(wire.into_iter().map(|revision| revision.model()).collect())
    }

    fn branches(&self) -> Result<Vec<VersionControlBranch>, VersionControlError> {
        let wire: Vec<BranchWire> = self.result(serde_json::json!({ "op": "branches" }))?;
        Ok(wire.into_iter().map(|branch| branch.model()).collect())
    }

    fn diff(&self, change: &VersionControlChange) -> Result<String, VersionControlError> {
        match self.perform(serde_json::json!({
            "op": "diff",
            "change": Self::wire(change),
        }))? {
            StepOutcome::Output(text) => Ok(text),
            StepOutcome::Result(data) => {
                Ok(serde_json::from_slice::<String>(&data).unwrap_or_default())
            }
        }
    }

    fn stage(&self, paths: &[String]) -> Result<(), VersionControlError> {
        self.perform(serde_json::json!({ "op": "stage", "paths": paths }))?;
        Ok(())
    }

    fn unstage(&self, paths: &[String]) -> Result<(), VersionControlError> {
        self.perform(serde_json::json!({ "op": "unstage", "paths": paths }))?;
        Ok(())
    }

    fn discard(&self, changes: &[VersionControlChange]) -> Result<(), VersionControlError> {
        self.perform(serde_json::json!({
            "op": "discard",
            "changes": changes.iter().map(Self::wire).collect::<Vec<_>>(),
        }))?;
        Ok(())
    }

    fn commit(&self, message: &str, stage_all: bool) -> Result<(), VersionControlError> {
        self.perform(serde_json::json!({
            "op": "commit",
            "message": message,
            "stageAll": stage_all,
        }))?;
        Ok(())
    }

    fn pull(&self) -> Result<(), VersionControlError> {
        self.perform(serde_json::json!({ "op": "pull" }))?;
        Ok(())
    }

    fn push(&self) -> Result<(), VersionControlError> {
        self.perform(serde_json::json!({ "op": "push" }))?;
        Ok(())
    }

    fn switch_branch(&self, name: &str) -> Result<(), VersionControlError> {
        self.perform(serde_json::json!({ "op": "switch-branch", "name": name }))?;
        Ok(())
    }

    fn create_branch(&self, name: &str) -> Result<(), VersionControlError> {
        self.perform(serde_json::json!({ "op": "create-branch", "name": name }))?;
        Ok(())
    }

    fn locks(&self) -> Result<BTreeSet<String>, VersionControlError> {
        let locks: Vec<String> = self.result(serde_json::json!({ "op": "locks" }))?;
        Ok(locks.into_iter().collect())
    }

    fn set_locked(&self, locked: bool, paths: &[String]) -> Result<(), VersionControlError> {
        self.perform(serde_json::json!({
            "op": "set-locked",
            "locked": locked,
            "paths": paths,
        }))?;
        Ok(())
    }
}

impl From<StepError> for VersionControlError {
    fn from(error: StepError) -> Self {
        match error {
            StepError::CommandFailed { command, message } => {
                VersionControlError::CommandFailed { command, message }
            }
            other => VersionControlError::Unsupported(other.to_string()),
        }
    }
}

// The JSON plugins return, decoded into the editor's model.

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StatusWire {
    #[serde(default)]
    branch: Option<String>,
    #[serde(default)]
    upstream: Option<String>,
    #[serde(default)]
    ahead: i64,
    #[serde(default)]
    behind: i64,
    #[serde(default)]
    changes: Vec<StatusChangeWire>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StatusChangeWire {
    path: String,
    #[serde(default)]
    original_path: Option<String>,
    state: VersionControlFileState,
    staged: bool,
}

impl StatusWire {
    fn model(self) -> VersionControlStatus {
        VersionControlStatus::with_changes(
            VersionControlTracking::with_options(
                self.branch,
                self.upstream,
                self.ahead,
                self.behind,
            ),
            self.changes
                .into_iter()
                .map(|change| {
                    VersionControlChange::with_original_path(
                        change.path,
                        change.original_path,
                        change.state,
                        change.staged,
                    )
                })
                .collect(),
        )
    }
}

#[derive(Debug, Deserialize)]
struct RevisionWire {
    id: String,
    summary: String,
    #[serde(default)]
    author: Option<String>,
    /// Seconds since 1970.
    #[serde(default)]
    date: Option<i64>,
}

impl RevisionWire {
    fn model(self) -> VersionControlRevision {
        let date = self
            .date
            .map(|seconds| SwiftDate(seconds as f64 - SWIFT_DATE_REFERENCE_UNIX_SECONDS as f64));
        VersionControlRevision::with_options(self.id, self.summary, self.author, date)
    }
}

#[derive(Debug, Deserialize)]
struct BranchWire {
    name: String,
    current: bool,
    #[serde(default)]
    remote: bool,
}

impl BranchWire {
    fn model(self) -> VersionControlBranch {
        VersionControlBranch::with_options(self.name, self.current, self.remote)
    }
}

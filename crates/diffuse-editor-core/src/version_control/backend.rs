//! `Editor/Sources/EditorCore/VersionControl/Backend.swift`.

use std::collections::BTreeSet;

use crate::version_control::model::{
    VersionControlBranch, VersionControlChange, VersionControlRepository, VersionControlRevision,
    VersionControlStatus, VersionControlSystem,
};

/// One version control system's command set. Every path is repository-relative.
/// Backends run their tool out of process and never invoke a shell.
pub trait VersionControlBackend: Send + Sync {
    fn repository(&self) -> &VersionControlRepository;
    fn status(&self) -> Result<VersionControlStatus, VersionControlError>;
    fn history(&self, limit: i64) -> Result<Vec<VersionControlRevision>, VersionControlError>;
    fn branches(&self) -> Result<Vec<VersionControlBranch>, VersionControlError>;
    /// A unified diff of one file against the last revision.
    fn diff(&self, change: &VersionControlChange) -> Result<String, VersionControlError>;
    fn stage(&self, paths: &[String]) -> Result<(), VersionControlError>;
    fn unstage(&self, paths: &[String]) -> Result<(), VersionControlError>;
    /// Restores files to the last revision; untracked files are removed.
    fn discard(&self, changes: &[VersionControlChange]) -> Result<(), VersionControlError>;
    /// Commits the staged changes, staging everything first when nothing is.
    fn commit(&self, message: &str, stage_all: bool) -> Result<(), VersionControlError>;
    fn pull(&self) -> Result<(), VersionControlError>;
    fn push(&self) -> Result<(), VersionControlError>;
    fn switch_branch(&self, name: &str) -> Result<(), VersionControlError>;
    fn create_branch(&self, name: &str) -> Result<(), VersionControlError>;
    /// Paths locked by this user; systems without locks return nothing.
    fn locks(&self) -> Result<BTreeSet<String>, VersionControlError>;
    fn set_locked(&self, locked: bool, paths: &[String]) -> Result<(), VersionControlError>;
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum VersionControlError {
    #[error("{}", tool_missing_message(.0))]
    ToolMissing(VersionControlSystem),
    #[error("{}", command_failed_message(.command, .message))]
    CommandFailed { command: String, message: String },
    #[error("{0}")]
    Unsupported(String),
    #[error("{0}")]
    InvalidInput(String),
}

fn tool_missing_message(system: &VersionControlSystem) -> String {
    format!(
        "The {} command-line tool was not found. Install it and make sure it is on PATH.",
        system.title()
    )
}

fn command_failed_message(command: &str, message: &str) -> String {
    if message.is_empty() {
        format!("{command} failed.")
    } else {
        message.to_string()
    }
}

impl VersionControlError {
    /// Swift's `LocalizedError.errorDescription`.
    pub fn error_description(&self) -> String {
        self.to_string()
    }
}

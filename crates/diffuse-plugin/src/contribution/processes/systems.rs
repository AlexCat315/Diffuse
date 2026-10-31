//! Version control systems and task providers driven through package entry
//! points.
//!
//! Ported from `Engine/Sources/PluginRuntime/Contribution/Processes/Systems.swift`.

use serde::{Deserialize, Serialize};

/// A version control system driven through the package's `provider` entry
/// point. The plugin decides every command; the host runs it under the
/// package's process permission and feeds the output back.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionControlContribution {
    /// The system's identifier, such as `git`.
    pub id: String,
    pub title: String,
    /// The file or directory that marks a working tree's root, such as `.git`.
    pub marker: String,
    /// The ignore file initialization extends, such as `.gitignore`.
    pub ignore_file: String,
    /// Breaks ties when one folder holds several systems' markers; higher wins.
    #[serde(default)]
    pub priority: Option<i64>,
}

impl VersionControlContribution {
    /// The capability every version control package exports.
    pub const ENTRY_POINT: &'static str = "provider";

    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        marker: impl Into<String>,
        ignore_file: impl Into<String>,
    ) -> Self {
        VersionControlContribution {
            id: id.into(),
            title: title.into(),
            marker: marker.into(),
            ignore_file: ignore_file.into(),
            priority: None,
        }
    }
}

/// Builds, tests and runs one kind of project through the package's `tasks`
/// entry point. The plugin decides each command and reads its output into
/// problems, tests and the project's description; the host runs the commands,
/// shows their output as it arrives and lists what the plugin read.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskContribution {
    /// The project kind's identifier, such as `swiftpm`.
    pub id: String,
    pub title: String,
    /// The file in the project folder that marks such a project, such as
    /// `Package.swift`.
    pub marker: String,
}

impl TaskContribution {
    pub const ENTRY_POINT: &'static str = "tasks";

    pub fn new(id: impl Into<String>, title: impl Into<String>, marker: impl Into<String>) -> Self {
        TaskContribution {
            id: id.into(),
            title: title.into(),
            marker: marker.into(),
        }
    }
}

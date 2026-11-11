//! `Editor/Sources/EditorCore/VersionControl/Model.swift`.

use std::collections::BTreeSet;
use std::path::PathBuf;

use diffuse_capability::support::swift_date::SwiftDate;
use serde::de::Error as _;
use serde::{Deserialize, Deserializer, Serialize, Serializer};

use crate::version_control::providers::VersionControlProvider;

/// The version control systems the editor can drive, each through a bundled
/// plugin. Git suits code and text; Lore adds a server-backed store and file
/// locks for large binary assets.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct VersionControlSystem {
    raw_value: String,
}

impl VersionControlSystem {
    /// `init?(rawValue:)` — `^[a-z][a-z0-9-]{0,31}$`.
    pub fn new(raw_value: impl Into<String>) -> Option<Self> {
        let raw_value = raw_value.into();
        let mut characters = raw_value.chars();
        let first = characters.next()?;
        let valid_length = (1..=32).contains(&raw_value.len());
        let valid = first.is_ascii_lowercase()
            && characters.all(|character| {
                character.is_ascii_lowercase() || character.is_ascii_digit() || character == '-'
            });
        (valid_length && valid).then_some(VersionControlSystem { raw_value })
    }

    pub fn git() -> Self {
        Self::new("git").expect("git is a valid version control identifier")
    }

    pub fn lore() -> Self {
        Self::new("lore").expect("lore is a valid version control identifier")
    }

    pub fn raw_value(&self) -> &str {
        &self.raw_value
    }

    /// Swift's `CaseIterable.allCases`: the bundled providers' systems.
    pub fn all_cases() -> Vec<VersionControlSystem> {
        VersionControlProvider::bundled()
            .iter()
            .map(|provider| provider.system.clone())
            .collect()
    }

    /// The display name its plugin contributes.
    pub fn title(&self) -> String {
        VersionControlProvider::provider_for(self)
            .map(|provider| provider.contribution.title.clone())
            .unwrap_or_else(|| self.raw_value.clone())
    }
}

impl Serialize for VersionControlSystem {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(&self.raw_value)
    }
}

impl<'de> Deserialize<'de> for VersionControlSystem {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = String::deserialize(deserializer)?;
        Self::new(raw).ok_or_else(|| D::Error::custom("Invalid VCS identifier"))
    }
}

/// What happened to a file relative to the last revision.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum VersionControlFileState {
    Modified,
    Added,
    Deleted,
    Renamed,
    Copied,
    Untracked,
    Conflicted,
}

impl VersionControlFileState {
    /// The one-letter badge used in file trees and change lists.
    pub fn badge(self) -> &'static str {
        match self {
            VersionControlFileState::Modified => "M",
            VersionControlFileState::Added => "A",
            VersionControlFileState::Deleted => "D",
            VersionControlFileState::Renamed => "R",
            VersionControlFileState::Copied => "C",
            VersionControlFileState::Untracked => "U",
            VersionControlFileState::Conflicted => "!",
        }
    }

    pub fn raw_value(self) -> &'static str {
        match self {
            VersionControlFileState::Modified => "modified",
            VersionControlFileState::Added => "added",
            VersionControlFileState::Deleted => "deleted",
            VersionControlFileState::Renamed => "renamed",
            VersionControlFileState::Copied => "copied",
            VersionControlFileState::Untracked => "untracked",
            VersionControlFileState::Conflicted => "conflicted",
        }
    }
}

/// One changed path. A file with both staged and unstaged edits appears twice,
/// once per area, as in Git's index model; Lore reports one entry per file.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct VersionControlChange {
    /// Repository-relative path using `/` separators.
    pub path: String,
    /// The previous path of a rename or copy.
    pub original_path: Option<String>,
    pub state: VersionControlFileState,
    pub is_staged: bool,
}

impl VersionControlChange {
    /// Swift's memberwise initializer with its `originalPath: nil` default.
    pub fn new(path: impl Into<String>, state: VersionControlFileState, is_staged: bool) -> Self {
        VersionControlChange {
            path: path.into(),
            original_path: None,
            state,
            is_staged,
        }
    }

    /// The full memberwise initializer.
    pub fn with_original_path(
        path: impl Into<String>,
        original_path: Option<String>,
        state: VersionControlFileState,
        is_staged: bool,
    ) -> Self {
        VersionControlChange {
            path: path.into(),
            original_path,
            state,
            is_staged,
        }
    }

    pub fn id(&self) -> String {
        format!(
            "{}{}",
            if self.is_staged { "staged:" } else { "work:" },
            self.path
        )
    }
}

/// One entry of the history list.
#[derive(Clone, Debug, PartialEq)]
pub struct VersionControlRevision {
    /// A Git hash or a Lore revision number.
    pub id: String,
    pub summary: String,
    pub author: Option<String>,
    pub date: Option<SwiftDate>,
}

impl VersionControlRevision {
    /// Swift's memberwise initializer with its `nil` defaults.
    pub fn new(id: impl Into<String>, summary: impl Into<String>) -> Self {
        VersionControlRevision {
            id: id.into(),
            summary: summary.into(),
            author: None,
            date: None,
        }
    }

    /// The full memberwise initializer.
    pub fn with_options(
        id: impl Into<String>,
        summary: impl Into<String>,
        author: Option<String>,
        date: Option<SwiftDate>,
    ) -> Self {
        VersionControlRevision {
            id: id.into(),
            summary: summary.into(),
            author,
            date,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct VersionControlBranch {
    pub name: String,
    pub is_current: bool,
    pub is_remote: bool,
}

impl VersionControlBranch {
    /// Swift's memberwise initializer with its `isRemote: false` default.
    pub fn new(name: impl Into<String>, is_current: bool) -> Self {
        VersionControlBranch {
            name: name.into(),
            is_current,
            is_remote: false,
        }
    }

    /// The full memberwise initializer.
    pub fn with_options(name: impl Into<String>, is_current: bool, is_remote: bool) -> Self {
        VersionControlBranch {
            name: name.into(),
            is_current,
            is_remote,
        }
    }

    pub fn id(&self) -> String {
        format!(
            "{}{}",
            if self.is_remote { "remote:" } else { "local:" },
            self.name
        )
    }
}

/// Where the working tree stands relative to its upstream.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct VersionControlTracking {
    pub branch: Option<String>,
    pub upstream: Option<String>,
    pub ahead: i64,
    pub behind: i64,
}

impl VersionControlTracking {
    /// Swift's memberwise initializer with its defaults.
    pub fn new() -> Self {
        Self::default()
    }

    /// The full memberwise initializer.
    pub fn with_options(
        branch: Option<String>,
        upstream: Option<String>,
        ahead: i64,
        behind: i64,
    ) -> Self {
        VersionControlTracking {
            branch,
            upstream,
            ahead,
            behind,
        }
    }
}

/// The result of reading a working tree once.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct VersionControlStatus {
    pub tracking: VersionControlTracking,
    pub changes: Vec<VersionControlChange>,
}

impl VersionControlStatus {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn with_changes(
        tracking: VersionControlTracking,
        changes: Vec<VersionControlChange>,
    ) -> Self {
        VersionControlStatus { tracking, changes }
    }
}

/// A repository the editor has found for the project.
#[derive(Clone, Debug, PartialEq)]
pub struct VersionControlRepository {
    pub system: VersionControlSystem,
    /// The working tree root; may be an ancestor of the project directory.
    pub root: PathBuf,
}

impl VersionControlRepository {
    pub fn new(system: VersionControlSystem, root: PathBuf) -> Self {
        VersionControlRepository { system, root }
    }
}

/// Long-running operations a user can start from the Source Control panel.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum VersionControlOperation {
    Staging,
    Unstaging,
    Discarding,
    Committing,
    Pulling,
    Pushing,
    SwitchingBranch,
    CreatingBranch,
    Initializing,
    Locking,
}

/// Everything views show about version control, compared as one value.
#[derive(Clone, Debug, PartialEq)]
pub struct VersionControlSnapshot {
    pub availability: VersionControlAvailability,
    pub status: VersionControlStatus,
    pub history: Vec<VersionControlRevision>,
    pub branches: Vec<VersionControlBranch>,
    /// Lore file locks held in this working tree, as repository paths.
    pub locks: BTreeSet<String>,
    pub operation: Option<VersionControlOperation>,
    pub error: Option<String>,
    /// Tools found on this machine, for the empty state's init actions.
    pub installed_systems: BTreeSet<VersionControlSystem>,
    /// Systems switched off in Settings; detection skips them.
    pub disabled_systems: BTreeSet<VersionControlSystem>,
    /// The change in the editor's diff tab.
    pub comparison: Option<VersionControlComparison>,
}

/// Swift's nested `VersionControlSnapshot.Availability`.
#[derive(Clone, Debug, PartialEq)]
pub enum VersionControlAvailability {
    /// Detection has not finished yet.
    Unknown,
    /// The project is not inside a working tree.
    NoRepository,
    /// A working tree exists but its command-line tool was not found.
    ToolMissing(VersionControlSystem),
    Ready(VersionControlRepository),
}

impl VersionControlSnapshot {
    pub fn new() -> Self {
        VersionControlSnapshot {
            availability: VersionControlAvailability::Unknown,
            status: VersionControlStatus::new(),
            history: Vec::new(),
            branches: Vec::new(),
            locks: BTreeSet::new(),
            operation: None,
            error: None,
            installed_systems: BTreeSet::new(),
            disabled_systems: BTreeSet::new(),
            comparison: None,
        }
    }

    pub fn repository(&self) -> Option<&VersionControlRepository> {
        match &self.availability {
            VersionControlAvailability::Ready(repository) => Some(repository),
            _ => None,
        }
    }

    pub fn staged(&self) -> Vec<&VersionControlChange> {
        self.status
            .changes
            .iter()
            .filter(|change| change.is_staged)
            .collect()
    }

    pub fn unstaged(&self) -> Vec<&VersionControlChange> {
        self.status
            .changes
            .iter()
            .filter(|change| !change.is_staged)
            .collect()
    }
}

impl Default for VersionControlSnapshot {
    fn default() -> Self {
        Self::new()
    }
}

/// A change shown in the editor's diff tab. It follows the file between the
/// staged and unstaged areas, and its diff is re-read after every refresh.
#[derive(Clone, Debug, PartialEq)]
pub struct VersionControlComparison {
    pub change: VersionControlChange,
    /// `None` while the diff loads.
    pub diff: Option<String>,
    /// False once the file has no change left, e.g. after a commit.
    pub is_current: bool,
}

impl VersionControlComparison {
    pub fn new(change: VersionControlChange) -> Self {
        VersionControlComparison {
            change,
            diff: None,
            is_current: true,
        }
    }
}

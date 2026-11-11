//! `Editor/Sources/EditorCore/Scripting/SourceKitLSP/Language/WatchedFiles.swift`.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// LSP `FileChangeType`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ScriptWatchedFileChangeType {
    Created = 1,
    Changed = 2,
    Deleted = 3,
}

impl ScriptWatchedFileChangeType {
    pub fn raw_value(self) -> i32 {
        self as i32
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ScriptWatchedFileChange {
    pub url: PathBuf,
    pub change_type: ScriptWatchedFileChangeType,
}

/// The project's files in the served language, and the file names its plugin
/// watches (such as a package manifest), by modification date, so edits made
/// outside the editor (a checkout, a generator, another editor) reach the
/// language server as `workspace/didChangeWatchedFiles`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct ScriptWatchedFiles {
    entries: BTreeMap<PathBuf, Option<SystemTime>>,
}

/// A folder this large is scanned no further, keeping each poll cheap.
const LIMIT: usize = 20_000;
const SKIPPED: [&str; 4] = ["node_modules", "DerivedData", "Pods", "Carthage"];
/// Extensions Foundation treats as packages under `.skipsPackageDescendants`.
const PACKAGE_EXTENSIONS: [&str; 10] = [
    "app",
    "bundle",
    "framework",
    "plugin",
    "xcodeproj",
    "xcworkspace",
    "playground",
    "pkg",
    "mpkg",
    "dSYM",
];

impl ScriptWatchedFiles {
    pub fn scan(root: &Path, extensions: &BTreeSet<String>, names: &BTreeSet<String>) -> Self {
        let mut result = Self::default();
        let mut visited = 0;
        scan_into(root, extensions, names, &mut visited, &mut result.entries);
        result
    }

    /// Whether `root` holds any file with one of `extensions`, stopping at the first.
    pub fn contains(root: &Path, extensions: &BTreeSet<String>) -> bool {
        if extensions.is_empty() {
            return false;
        }
        let mut visited = 0;
        contains_in(root, extensions, &mut visited)
    }

    pub fn changes(&self, next: &Self) -> Vec<ScriptWatchedFileChange> {
        let mut changes: Vec<ScriptWatchedFileChange> = Vec::new();
        for (url, date) in &next.entries {
            match self.entries.get(url) {
                Some(previous) if previous == date => {}
                Some(_) => changes.push(ScriptWatchedFileChange {
                    url: url.clone(),
                    change_type: ScriptWatchedFileChangeType::Changed,
                }),
                None => changes.push(ScriptWatchedFileChange {
                    url: url.clone(),
                    change_type: ScriptWatchedFileChangeType::Created,
                }),
            }
        }
        for url in self.entries.keys() {
            if !next.entries.contains_key(url) {
                changes.push(ScriptWatchedFileChange {
                    url: url.clone(),
                    change_type: ScriptWatchedFileChangeType::Deleted,
                });
            }
        }
        changes.sort_by(|left, right| left.url.to_string_lossy().cmp(&right.url.to_string_lossy()));
        changes
    }
}

fn scan_into(
    root: &Path,
    extensions: &BTreeSet<String>,
    names: &BTreeSet<String>,
    visited: &mut usize,
    entries: &mut BTreeMap<PathBuf, Option<SystemTime>>,
) {
    let Ok(directory) = fs::read_dir(root) else {
        return;
    };
    for entry in directory.flatten() {
        let path = entry.path();
        let Some(name) = file_name(&path) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        *visited += 1;
        if *visited > LIMIT {
            return;
        }
        // `file_type` does not follow symlinks, matching the enumerator: a
        // symlinked directory is yielded as an entry and never descended into.
        let Ok(file_type) = entry.file_type() else {
            continue;
        };
        if file_type.is_dir() {
            if SKIPPED.contains(&name) || is_package_directory(&path) {
                continue;
            }
            scan_into(&path, extensions, names, visited, entries);
            continue;
        }
        let extension = path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        if !(extensions.contains(extension) || names.contains(name)) {
            continue;
        }
        entries.insert(
            path.clone(),
            entry.metadata().ok().and_then(|m| m.modified().ok()),
        );
    }
}

fn contains_in(root: &Path, extensions: &BTreeSet<String>, visited: &mut usize) -> bool {
    let Ok(directory) = fs::read_dir(root) else {
        return false;
    };
    for entry in directory.flatten() {
        let path = entry.path();
        let Some(name) = file_name(&path) else {
            continue;
        };
        if name.starts_with('.') {
            continue;
        }
        *visited += 1;
        if *visited > LIMIT {
            return false;
        }
        let is_directory = entry.file_type().map(|kind| kind.is_dir()).unwrap_or(false);
        if is_directory {
            if SKIPPED.contains(&name) || is_package_directory(&path) {
                continue;
            }
            if contains_in(&path, extensions, visited) {
                return true;
            }
            continue;
        }
        let extension = path
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        if extensions.contains(extension) {
            return true;
        }
    }
    false
}

fn file_name(path: &Path) -> Option<&str> {
    path.file_name().and_then(|value| value.to_str())
}

fn is_package_directory(path: &Path) -> bool {
    let Some(extension) = path.extension().and_then(|value| value.to_str()) else {
        return false;
    };
    PACKAGE_EXTENSIONS
        .iter()
        .any(|candidate| candidate.eq_ignore_ascii_case(extension))
}

//! Depth-first project resource traversal with per-directory pruning.
//!
//! Ported from `Engine/Sources/AssetPipeline/ProjectResourceWalker.swift`.
//!
//! Each directory is traversed independently, so pruning one subtree never
//! changes whether later sibling directories are visited — Windows Foundation's
//! `DirectoryEnumerator.skipDescendants()` used to persist its shallow-walk
//! option across siblings, and walking each directory separately avoids it.

use std::path::{Path, PathBuf};

/// Failure to enumerate a directory.
#[derive(Debug, thiserror::Error)]
pub enum ProjectResourceWalkerError {
    #[error("{path}: {message}")]
    Unreadable { path: String, message: String },
}

/// Every regular file under `root`, sorted by path.
///
/// Symbolic links are skipped entirely (to files and to directories alike),
/// which keeps the scan inside the project and makes link cycles impossible. A
/// directory satisfying `excluding_directory` is not descended into. When
/// `continue_on_error` is false the first unreadable entry aborts the walk; when
/// true that entry is skipped and the walk continues.
pub fn files(
    root: &Path,
    continue_on_error: bool,
    excluding_directory: impl Fn(&Path) -> bool,
) -> Result<Vec<PathBuf>, ProjectResourceWalkerError> {
    let mut pending: Vec<PathBuf> = vec![root.to_path_buf()];
    let mut collected: Vec<PathBuf> = Vec::new();
    while let Some(directory) = pending.pop() {
        let entries = match std::fs::read_dir(&directory) {
            Ok(entries) => entries,
            Err(error) => {
                if continue_on_error {
                    continue;
                }
                return Err(ProjectResourceWalkerError::Unreadable {
                    path: directory.to_string_lossy().into_owned(),
                    message: error.to_string(),
                });
            }
        };
        for entry in entries {
            let entry = match entry {
                Ok(entry) => entry,
                Err(error) => {
                    if continue_on_error {
                        continue;
                    }
                    return Err(ProjectResourceWalkerError::Unreadable {
                        path: directory.to_string_lossy().into_owned(),
                        message: error.to_string(),
                    });
                }
            };
            let path = entry.path();
            // `contentsOfDirectory(options: .skipsHiddenFiles)` drops hidden
            // entries before any other classification happens.
            if is_hidden(&path) {
                continue;
            }
            let metadata = match std::fs::symlink_metadata(&path) {
                Ok(metadata) => metadata,
                Err(error) => {
                    if continue_on_error {
                        continue;
                    }
                    return Err(ProjectResourceWalkerError::Unreadable {
                        path: path.to_string_lossy().into_owned(),
                        message: error.to_string(),
                    });
                }
            };
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                if !is_package(&path) && !excluding_directory(&path) {
                    pending.push(path);
                }
            } else if metadata.is_file() {
                collected.push(path);
            }
        }
    }
    collected.sort();
    Ok(collected)
}

/// `.skipsHiddenFiles`: a dot-prefixed name is hidden on every platform.
fn is_hidden(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.starts_with('.'))
        .unwrap_or(false)
}

/// `URLResourceValues.isPackage`: a directory with a known bundle extension.
/// That extension test is the portable part of Foundation's package detection,
/// and it is what `.skipsPackageDescendants` reduces to for an asset scan.
fn is_package(path: &Path) -> bool {
    const PACKAGE_EXTENSIONS: [&str; 12] = [
        "app",
        "bundle",
        "framework",
        "plugin",
        "kext",
        "xpc",
        "appex",
        "scptd",
        "dmg",
        "pkg",
        "xcarchive",
        "playground",
    ];
    path.extension()
        .and_then(|extension| extension.to_str())
        .map(|extension| PACKAGE_EXTENSIONS.contains(&extension.to_ascii_lowercase().as_str()))
        .unwrap_or(false)
}

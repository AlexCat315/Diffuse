//! Locates the SDK checkout every tool operates on, independent of the caller's
//! working directory, and exposes the small set of well-known roots.

use super::terminal::{Terminal, ToolError};
use std::path::{Path, PathBuf};

/// Environment override for the checkout root.
pub const ROOT_OVERRIDE: &str = "COVE_ROOT";
/// Marker that identifies a source checkout.
pub const CHECKOUT_MARKER: &str = "Tools/Developer/Package.swift";

/// Absolute path of the SDK checkout.
pub fn root() -> PathBuf {
    if let Some(override_path) = std::env::var_os(ROOT_OVERRIDE) {
        let override_path = PathBuf::from(override_path);
        if !override_path.as_os_str().is_empty() {
            return standardized(&override_path);
        }
    }
    let current = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    for directory in current.ancestors() {
        if directory.join(CHECKOUT_MARKER).is_file() {
            return directory.to_path_buf();
        }
    }
    Terminal::fail("Run cove-dev from inside a source checkout or set COVE_ROOT")
}

/// Joins a repository-relative path onto the checkout root.
pub fn path(relative: &str) -> PathBuf {
    root().join(relative)
}

/// Resolves a repository-relative path or fails with the missing path.
pub fn require(relative: &str) -> Result<PathBuf, ToolError> {
    let url = path(relative);
    if !url.exists() {
        return Err(ToolError::message(format!(
            "Missing required path: {relative}"
        )));
    }
    Ok(url)
}

/// Lexically removes `.` and resolves `..` without touching the filesystem,
/// matching Foundation's `standardizedFileURL`.
pub fn standardized(url: &Path) -> PathBuf {
    let mut result = PathBuf::new();
    for component in url.components() {
        match component {
            std::path::Component::ParentDir => {
                result.pop();
            }
            std::path::Component::CurDir => {}
            other => result.push(other.as_os_str()),
        }
    }
    result
}

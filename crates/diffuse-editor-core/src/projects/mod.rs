pub mod editor_project_lifecycle;
pub mod editor_scratch_workspace;

use std::path::{Component, Path, PathBuf};

/// Canonical form of a project path.
///
/// Resolves symlinks when the path exists, matching
/// `URL.standardizedFileURL.resolvingSymlinksInPath()`. A path that does not
/// exist yet — a project the user just picked — is made absolute and lexically
/// normalized instead, which is what `standardizedFileURL` does on its own.
pub fn standardized_path(path: &Path) -> PathBuf {
    if let Ok(canonical) = std::fs::canonicalize(path) {
        return without_verbatim_prefix(canonical);
    }
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.join(path))
            .unwrap_or_else(|_| path.to_path_buf())
    };
    let mut normalized = PathBuf::new();
    for component in absolute.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized
}

/// Windows `canonicalize` returns verbatim paths (`\\?\C:\…`), which are the
/// same directory but read as a different string. Swift's
/// `resolvingSymlinksInPath()` never introduces that prefix.
#[cfg(windows)]
fn without_verbatim_prefix(path: PathBuf) -> PathBuf {
    let text = path.to_string_lossy();
    if let Some(rest) = text.strip_prefix(r"\\?\UNC\") {
        return PathBuf::from(format!(r"\\{rest}"));
    }
    if let Some(rest) = text.strip_prefix(r"\\?\") {
        return PathBuf::from(rest);
    }
    path
}

#[cfg(not(windows))]
fn without_verbatim_prefix(path: PathBuf) -> PathBuf {
    path
}

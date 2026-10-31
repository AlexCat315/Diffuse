//! `WorkspaceTrash` — recoverable removal of workspace-relative files.

use std::fs;
use std::path::{Path, PathBuf};

use crate::workspace::DocumentError;

/// Recoverable removal of workspace-relative files, including hidden project files.
pub struct WorkspaceTrash;

impl WorkspaceTrash {
    /// `remove(_:in:)`.
    ///
    /// Rejects paths that leave the workspace, traverse a symlink, or start with
    /// the `.cove` component. macOS uses the native Trash; other hosts retain the
    /// item under `.cove/trash/<UUID>/<path>`, matching Swift.
    pub fn remove(path: &str, root: &Path) -> Result<(), DocumentError> {
        let components: Vec<&str> = path.split('/').filter(|part| !part.is_empty()).collect();
        let valid = !components.is_empty()
            && !path.starts_with('/')
            && !path.contains('\\')
            && !path.contains(':')
            && !components.iter().any(|part| *part == "." || *part == "..")
            && components.first() != Some(&".cove");
        if !valid {
            return Err(DocumentError::InvalidPath);
        }

        let mut source = resolve_root(root);
        for component in &components {
            source.push(component);
            if is_symbolic_link(&source) {
                return Err(DocumentError::InvalidPath);
            }
        }

        if !source.exists() {
            return Ok(());
        }

        #[cfg(target_os = "macos")]
        {
            // The native Trash ignores the recovery directory; passing the same
            // `.cove/trash` location keeps both branches consistent.
            let recovery = resolve_root(root).join(".cove/trash");
            cove_system::files::trash(&source, &recovery)
                .map_err(|_| DocumentError::InvalidPath)?;
            Ok(())
        }
        #[cfg(not(target_os = "macos"))]
        {
            let mut trash = resolve_root(root);
            for component in [".cove", "trash"] {
                trash.push(component);
                if is_symbolic_link(&trash) {
                    return Err(DocumentError::InvalidPath);
                }
            }
            let destination = trash.join(uuid_string()).join(path);
            if let Some(parent) = destination.parent() {
                fs::create_dir_all(parent).map_err(|_| DocumentError::InvalidPath)?;
            }
            fs::rename(&source, &destination).map_err(|_| DocumentError::InvalidPath)?;
            Ok(())
        }
    }
}

/// `URL.resolvingSymlinksInPath().standardizedFileURL` for a root that may not
/// exist yet: the longest existing ancestor is resolved, the remainder appended.
pub(crate) fn resolve_root(root: &Path) -> PathBuf {
    cove_system::files::resolve_path(root).unwrap_or_else(|_| root.to_path_buf())
}

/// Swift's `(try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true`.
pub(crate) fn is_symbolic_link(path: &Path) -> bool {
    fs::symlink_metadata(path)
        .map(|metadata| metadata.file_type().is_symlink())
        .unwrap_or(false)
}

/// A random v4 UUID formatted like Swift's `UUID().uuidString` (uppercase).
#[cfg(not(target_os = "macos"))]
fn uuid_string() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_nanos() as u64)
        .unwrap_or(0);
    let counter = COUNTER.fetch_add(1, Ordering::Relaxed);
    let mixed = nanos ^ counter.wrapping_mul(0x9E37_79B9_7F4A_7C15);
    let time_low = (mixed & 0xFFFF_FFFF) as u32;
    let time_mid = ((mixed >> 32) & 0xFFFF) as u16;
    let time_hi = (((mixed >> 48) & 0x0FFF) as u16) | 0x4000;
    let clock = ((counter & 0x3FFF) as u16) | 0x8000;
    let node: u64 = (mixed >> 8) & 0x0000_FFFF_FFFF_FFFF;
    format!("{time_low:08X}-{time_mid:04X}-{time_hi:04X}-{clock:04X}-{node:012X}")
}

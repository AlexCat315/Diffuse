//! `Editor/Sources/EditorCore/Projects/EditorScratchWorkspace.swift`.
//!
//! The workspace a window falls back to when it has no project.
//!
//! Everything the editor does — panels, the script workspace, the agent's file
//! tools, autosave — is rooted in a project directory, so "no project" cannot
//! mean "no directory". This is a real project folder in Application Support:
//! the workbench and the agent both work in it without the user choosing one
//! first, and whatever they save there survives to the next launch.
//!
//! It is deliberately never written to the saved project list, so the next
//! launch restores the user's real projects instead of reopening this one.

use std::path::{Component, Path, PathBuf};

pub struct EditorScratchWorkspace;

impl EditorScratchWorkspace {
    /// Stable location, so a scratch session keeps what it saved last time.
    pub fn directory() -> PathBuf {
        application_support_directory()
            .join("Cove")
            .join("Untitled")
    }

    /// Canonical form, matching how the project list and launcher compare paths.
    pub fn canonical_path() -> PathBuf {
        standardized_path(&Self::directory())
    }

    pub fn is_scratch(path: &Path) -> bool {
        standardized_path(path) == Self::canonical_path()
    }

    /// Creates the folder when it is missing.
    ///
    /// Deliberately **not** a project: no `.cove/project.json`, no descriptor, no
    /// name. `EditorApplication` only needs a directory to root its caches and
    /// the agent's file tools in, and `EditorProjectLifecycle::inspect` is never
    /// run against this path, so nothing can mistake it for something the user
    /// opened.
    pub fn prepare() -> std::io::Result<PathBuf> {
        let directory = Self::directory();
        std::fs::create_dir_all(&directory)?;
        remove_stale_descriptor(&directory);
        Ok(directory)
    }
}

/// Before this workspace existed, opening it went through the project
/// adoption path, which wrote a descriptor named "Untitled". That is exactly
/// the placeholder this workspace replaces, so every open removes it —
/// otherwise an existing install keeps listing a project the user never made.
/// Only this one file inside the editor's own folder is touched; nothing of
/// the user's is involved.
fn remove_stale_descriptor(directory: &Path) {
    let descriptor = directory.join(".cove").join("project.json");
    if !descriptor.exists() {
        return;
    }
    let _ = std::fs::remove_file(&descriptor);
}

/// Canonical form when the path exists, otherwise an absolute lexically
/// normalized path — matching `standardizedFileURL`.
fn standardized_path(path: &Path) -> PathBuf {
    if let Ok(canonical) = std::fs::canonicalize(path) {
        return canonical;
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

/// `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]`.
fn application_support_directory() -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        home_directory()
            .map(|home| home.join("Library").join("Application Support"))
            .unwrap_or_else(std::env::temp_dir)
    }
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(std::env::temp_dir)
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| home_directory().map(|home| home.join(".local").join("share")))
            .unwrap_or_else(std::env::temp_dir)
    }
}

fn home_directory() -> Option<PathBuf> {
    #[cfg(windows)]
    {
        std::env::var_os("USERPROFILE").map(PathBuf::from)
    }
    #[cfg(not(windows))]
    {
        std::env::var_os("HOME").map(PathBuf::from)
    }
}

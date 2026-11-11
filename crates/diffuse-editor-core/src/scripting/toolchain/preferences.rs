//! `Editor/Sources/EditorCore/Scripting/Toolchain/Preferences.swift`.

use std::path::{Path, PathBuf};

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SwiftToolchainPreferences {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub selected_path: Option<String>,
    #[serde(default = "default_release_version")]
    pub release_version: String,
}

fn default_release_version() -> String {
    "6.4.1".to_string()
}

impl SwiftToolchainPreferences {
    pub fn new() -> Self {
        SwiftToolchainPreferences {
            selected_path: None,
            release_version: default_release_version(),
        }
    }

    pub fn directory() -> PathBuf {
        let base = application_support_directory()
            .or_else(|| home_directory().map(|home| home.join(".local").join("share")))
            .unwrap_or_else(std::env::temp_dir);
        base.join("Diffuse").join("SwiftToolchains")
    }

    pub fn load(from: &Path) -> Self {
        let Ok(data) = std::fs::read(from.join("preferences.json")) else {
            return Self::new();
        };
        serde_json::from_slice(&data).unwrap_or_else(|_| Self::new())
    }

    /// Swift's `from directory: URL = Self.directory` default.
    pub fn load_with_default() -> Self {
        Self::load(&Self::directory())
    }

    pub fn save(&self, directory: &Path) -> std::io::Result<()> {
        std::fs::create_dir_all(directory)?;
        let data = serde_json::to_vec(self).map_err(std::io::Error::other)?;
        AtomicFile::write(&data, &directory.join("preferences.json"), Access::Inherit)
    }

    /// Swift's `to directory: URL = Self.directory` default.
    pub fn save_with_default(&self) -> std::io::Result<()> {
        self.save(&Self::directory())
    }
}

impl Default for SwiftToolchainPreferences {
    fn default() -> Self {
        Self::new()
    }
}

/// `FileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)`
/// first entry.
fn application_support_directory() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        home_directory().map(|home| home.join("Library").join("Application Support"))
    }
    #[cfg(target_os = "windows")]
    {
        std::env::var_os("APPDATA").map(PathBuf::from)
    }
    #[cfg(not(any(target_os = "macos", target_os = "windows")))]
    {
        std::env::var_os("XDG_DATA_HOME").map(PathBuf::from)
    }
}

/// `FileManager.default.homeDirectoryForCurrentUser`.
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

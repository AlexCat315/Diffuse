//! `Editor/Sources/EditorCore/Scripting/Toolchain/EditingPreferences.swift`.

use std::path::PathBuf;

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use serde::{Deserialize, Serialize};

use super::preferences::SwiftToolchainPreferences;

/// How Swift files are edited, for every project on this machine.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SwiftEditingPreferences {
    /// Saving a Swift file formats it through the language service first.
    #[serde(default)]
    pub formats_on_save: bool,
}

impl SwiftEditingPreferences {
    pub fn new() -> Self {
        SwiftEditingPreferences {
            formats_on_save: false,
        }
    }

    fn url() -> PathBuf {
        SwiftToolchainPreferences::directory()
            .parent()
            .map(|directory| directory.to_path_buf())
            .unwrap_or_default()
            .join("Swift")
            .join("editing.json")
    }

    pub fn load() -> Self {
        let Ok(data) = std::fs::read(Self::url()) else {
            return Self::new();
        };
        serde_json::from_slice(&data).unwrap_or_else(|_| Self::new())
    }

    pub fn save(&self) -> std::io::Result<()> {
        let url = Self::url();
        if let Some(directory) = url.parent() {
            std::fs::create_dir_all(directory)?;
        }
        let data = serde_json::to_vec(self).map_err(std::io::Error::other)?;
        AtomicFile::write(&data, &url, Access::Inherit)
    }
}

impl Default for SwiftEditingPreferences {
    fn default() -> Self {
        Self::new()
    }
}

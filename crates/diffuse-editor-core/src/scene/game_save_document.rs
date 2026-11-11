//! `Editor/Sources/EditorCore/Scene/GameSaveDocument.swift`.
//!
//! A point-in-time snapshot of the runtime scene, suitable for game progress
//! saves. Files are stored under `.cove/game-saves/slot-{slot}.json`.

use std::path::{Path, PathBuf};

use cove_system::atomic_file::AtomicFile;
use cove_system::files::Access;
use diffuse_assets::swift_json::to_sorted_pretty;
use serde::{Deserialize, Serialize};

use crate::scene::manifest::editor_scene_manifest::{
    EditorSceneManifest, EditorSceneManifestLoadError,
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GameSaveDocument {
    pub schema_version: i64,
    /// Save slot index (0-based). Slot 255 is reserved for the auto-save.
    pub slot: i64,
    pub saved_at: String,
    /// The full runtime manifest captured at save time.
    pub manifest: EditorSceneManifest,
}

impl GameSaveDocument {
    /// Swift's `static let currentSchemaVersion`.
    pub const CURRENT_SCHEMA_VERSION: i64 = 2;
    /// Swift's `static let autoSaveSlot`.
    pub const AUTO_SAVE_SLOT: i64 = 255;

    /// Swift's initializer stamps the current time as an ISO 8601 UTC string.
    pub fn new(slot: i64, manifest: EditorSceneManifest) -> Self {
        GameSaveDocument {
            schema_version: Self::CURRENT_SCHEMA_VERSION,
            slot,
            saved_at: iso8601_now(),
            manifest,
        }
    }
}

impl GameSaveDocument {
    /// The file for `slot` relative to `project_directory`.
    pub fn url(slot: i64, project_directory: &Path) -> PathBuf {
        project_directory
            .join(".cove")
            .join("game-saves")
            .join(format!("slot-{slot}.json"))
    }

    /// Encodes and writes this document atomically. Creates intermediate directories.
    pub fn write(&self, url: &Path) -> Result<(), GameSaveDocumentError> {
        if let Some(parent) = url.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| GameSaveDocumentError::Io(error.to_string()))?;
        }
        let text = to_sorted_pretty(self)
            .map_err(|error| GameSaveDocumentError::Encode(error.to_string()))?;
        AtomicFile::write(text.as_bytes(), url, Access::Inherit)
            .map_err(|error| GameSaveDocumentError::Io(error.to_string()))
    }

    /// Reads and decodes a `GameSaveDocument` from `url`, or returns `None` if the
    /// file does not exist.
    pub fn read(url: &Path) -> Result<Option<GameSaveDocument>, GameSaveDocumentError> {
        if !url.exists() {
            return Ok(None);
        }
        let data =
            std::fs::read(url).map_err(|error| GameSaveDocumentError::Io(error.to_string()))?;
        let document: GameSaveDocument = serde_json::from_slice(&data)
            .map_err(|error| GameSaveDocumentError::Decode(error.to_string()))?;
        if document.schema_version != Self::CURRENT_SCHEMA_VERSION {
            return Err(GameSaveDocumentError::UnsupportedVersion(
                document.schema_version,
            ));
        }
        if document.manifest.schema_version != EditorSceneManifest::CURRENT_SCHEMA_VERSION {
            return Err(GameSaveDocumentError::Manifest(
                EditorSceneManifestLoadError::UnsupportedVersion(document.manifest.schema_version),
            ));
        }
        Ok(Some(document))
    }
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum GameSaveDocumentError {
    #[error("unsupported game save version {0}")]
    UnsupportedVersion(i64),
    #[error(transparent)]
    Manifest(#[from] EditorSceneManifestLoadError),
    #[error("{0}")]
    Io(String),
    #[error("{0}")]
    Decode(String),
    #[error("{0}")]
    Encode(String),
}

/// `ISO8601DateFormatter().string(from: Date())`: UTC, second precision.
fn iso8601_now() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs_f64())
        .unwrap_or(0.0);
    cove_logging::iso8601(now.floor()).replace(".000Z", "Z")
}

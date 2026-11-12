//! Translation of `Editor/Sources/GameRuntime/GameProjectSceneLoader.swift`.
//!
//! Loads the startup scene for both exported bundles and development projects.
//! Exported bundles are strict: their descriptor, declared save, slot and entity
//! count must agree. Development projects without `build.json` retain the
//! optional slot-0 behavior used by CovePlayer during authoring.

use std::fmt;
use std::path::Path;

use diffuse_editor_core::scene::game_save_document::{GameSaveDocument, GameSaveDocumentError};
use diffuse_editor_core::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use diffuse_editor_core::scene::project_exporter::{ProjectExportError, ProjectExporter};

/// Swift's `GameProjectSceneLoadError`.
#[derive(Debug)]
pub enum GameProjectSceneLoadError {
    UnsupportedExportVersion(i64),
    InvalidSceneSlot(i64),
    MissingExportedScene(i64),
    SceneSlotMismatch {
        expected: i64,
        actual: i64,
    },
    EntityCountMismatch {
        expected: i64,
        actual: i64,
    },
    /// Swift rethrew descriptor errors; Rust names the wrapped error.
    Export(ProjectExportError),
    /// Swift rethrew save errors; Rust names the wrapped error.
    Save(GameSaveDocumentError),
}

impl fmt::Display for GameProjectSceneLoadError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnsupportedExportVersion(version) => {
                write!(formatter, "unsupported project export version: {version}")
            }
            Self::InvalidSceneSlot(slot) => {
                write!(
                    formatter,
                    "project export declares an invalid scene slot: {slot}"
                )
            }
            Self::MissingExportedScene(slot) => write!(
                formatter,
                "project export is missing its scene save for slot {slot}"
            ),
            Self::SceneSlotMismatch { expected, actual } => write!(
                formatter,
                "project scene slot mismatch (expected {expected}, found {actual})"
            ),
            Self::EntityCountMismatch { expected, actual } => write!(
                formatter,
                "project entity count mismatch (expected {expected}, found {actual})"
            ),
            Self::Export(error) => error.fmt(formatter),
            Self::Save(error) => error.fmt(formatter),
        }
    }
}

impl std::error::Error for GameProjectSceneLoadError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Export(error) => Some(error),
            Self::Save(error) => Some(error),
            _ => None,
        }
    }
}

impl From<ProjectExportError> for GameProjectSceneLoadError {
    fn from(error: ProjectExportError) -> Self {
        Self::Export(error)
    }
}

impl From<GameSaveDocumentError> for GameProjectSceneLoadError {
    fn from(error: GameSaveDocumentError) -> Self {
        Self::Save(error)
    }
}

pub struct GameProjectSceneLoader;

impl GameProjectSceneLoader {
    pub fn load(
        project_directory: &Path,
    ) -> Result<Option<EditorSceneManifest>, GameProjectSceneLoadError> {
        let descriptor_url = project_directory.join("build.json");
        let descriptor = if descriptor_url.exists() {
            let decoded = ProjectExporter::read_descriptor(project_directory)?;
            if decoded.schema_version != ProjectExporter::SCHEMA_VERSION {
                return Err(GameProjectSceneLoadError::UnsupportedExportVersion(
                    decoded.schema_version,
                ));
            }
            if decoded.scene_slot < 0 {
                return Err(GameProjectSceneLoadError::InvalidSceneSlot(
                    decoded.scene_slot,
                ));
            }
            Some(decoded)
        } else {
            None
        };

        let slot = descriptor
            .as_ref()
            .map_or(ProjectExporter::SCENE_SLOT, |descriptor| {
                descriptor.scene_slot
            });
        let scene_url = GameSaveDocument::url(slot, project_directory);
        let Some(document) = GameSaveDocument::read(&scene_url)? else {
            if descriptor.is_some() {
                return Err(GameProjectSceneLoadError::MissingExportedScene(slot));
            }
            return Ok(None);
        };
        if document.slot != slot {
            return Err(GameProjectSceneLoadError::SceneSlotMismatch {
                expected: slot,
                actual: document.slot,
            });
        }
        if let Some(descriptor) = descriptor.as_ref()
            && document.manifest.entity_count != descriptor.entity_count
        {
            return Err(GameProjectSceneLoadError::EntityCountMismatch {
                expected: descriptor.entity_count,
                actual: document.manifest.entity_count,
            });
        }
        Ok(Some(document.manifest))
    }
}

//! `Editor/Sources/EditorCore/Scene/Manifest/EditorSceneManifest.swift`.

use serde::{Deserialize, Serialize};

use crate::scene::manifest::node::EditorSceneManifestNode;
use crate::scene::manifest::settings::{
    EditorSceneManifestParticleScalability, EditorSceneManifestParticleScalabilityPolicy,
    EditorSceneManifestPhysicsSettings,
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EditorSceneManifest {
    pub schema_version: i64,
    pub revision: u64,
    pub entity_count: i64,
    #[serde(rename = "selectedEntityID", default)]
    pub selected_entity_id: Option<u64>,
    #[serde(default)]
    pub scene_kind: Option<String>,
    #[serde(default)]
    pub physics_settings: Option<EditorSceneManifestPhysicsSettings>,
    #[serde(default)]
    pub particle_scalability: Option<EditorSceneManifestParticleScalability>,
    #[serde(default)]
    pub particle_scalability_policy: Option<EditorSceneManifestParticleScalabilityPolicy>,
    #[serde(default)]
    pub project_asset_count: Option<i64>,
    #[serde(default)]
    pub last_modified_at: Option<String>,
    /// Editor-only hierarchy locks.
    #[serde(rename = "lockedEntityIDs", default)]
    pub locked_entity_ids: Option<Vec<u64>>,
    pub roots: Vec<EditorSceneManifestNode>,
}

impl EditorSceneManifest {
    /// Swift's `static let currentSchemaVersion`.
    pub const CURRENT_SCHEMA_VERSION: i64 = 8;

    /// Swift's initializer reduced to the arguments callers always pass.
    pub fn new(revision: u64, entity_count: i64, roots: Vec<EditorSceneManifestNode>) -> Self {
        EditorSceneManifest {
            schema_version: Self::CURRENT_SCHEMA_VERSION,
            revision,
            entity_count,
            selected_entity_id: None,
            scene_kind: None,
            physics_settings: None,
            particle_scalability: None,
            particle_scalability_policy: None,
            project_asset_count: None,
            last_modified_at: None,
            locked_entity_ids: None,
            roots,
        }
    }

    /// The full memberwise initializer.
    #[allow(clippy::too_many_arguments)]
    pub fn with_options(
        schema_version: i64,
        revision: u64,
        entity_count: i64,
        selected_entity_id: Option<u64>,
        scene_kind: Option<String>,
        physics_settings: Option<EditorSceneManifestPhysicsSettings>,
        particle_scalability: Option<EditorSceneManifestParticleScalability>,
        particle_scalability_policy: Option<EditorSceneManifestParticleScalabilityPolicy>,
        project_asset_count: Option<i64>,
        last_modified_at: Option<String>,
        locked_entity_ids: Option<Vec<u64>>,
        roots: Vec<EditorSceneManifestNode>,
    ) -> Self {
        EditorSceneManifest {
            schema_version,
            revision,
            entity_count,
            selected_entity_id,
            scene_kind,
            physics_settings,
            particle_scalability,
            particle_scalability_policy,
            project_asset_count,
            last_modified_at,
            locked_entity_ids,
            roots,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorSceneManifestLoadResult {
    pub entity_count: i64,
    pub selected_entity_id: Option<u64>,
    pub error: Option<EditorSceneManifestLoadError>,
}

impl EditorSceneManifestLoadResult {
    /// Swift's memberwise initializer with its `error: nil` default.
    pub fn new(entity_count: i64, selected_entity_id: Option<u64>) -> Self {
        EditorSceneManifestLoadResult {
            entity_count,
            selected_entity_id,
            error: None,
        }
    }

    /// The full initializer.
    pub fn with_error(
        entity_count: i64,
        selected_entity_id: Option<u64>,
        error: Option<EditorSceneManifestLoadError>,
    ) -> Self {
        EditorSceneManifestLoadResult {
            entity_count,
            selected_entity_id,
            error,
        }
    }

    pub fn succeeded(&self) -> bool {
        self.error.is_none()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, thiserror::Error)]
pub enum EditorSceneManifestLoadError {
    #[error("unsupported scene manifest version {0}")]
    UnsupportedVersion(i64),
}

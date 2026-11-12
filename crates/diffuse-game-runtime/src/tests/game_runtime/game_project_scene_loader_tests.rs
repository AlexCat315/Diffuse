//! Ported from `Editor/Tests/GameRuntimeTests/GameProjectSceneLoaderTests.swift`.

use std::path::{Path, PathBuf};

use diffuse_assets::swift_json;
use diffuse_editor_core::scene::game_save_document::GameSaveDocument;
use diffuse_editor_core::scene::manifest::editor_scene_manifest::EditorSceneManifest;
use diffuse_editor_core::scene::project_exporter::{ProjectExportDescriptor, ProjectExporter};
use diffuse_kernel::codable::new_uuid;

use crate::game_project_scene_loader::{GameProjectSceneLoadError, GameProjectSceneLoader};

struct TemporaryProject(PathBuf);

impl TemporaryProject {
    fn new(prefix: &str) -> Self {
        let url = std::env::temp_dir().join(format!("{prefix}-{}", new_uuid()));
        std::fs::create_dir_all(&url).expect("temporary project");
        Self(url)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TemporaryProject {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

macro_rules! write_json {
    ($project:expr, $name:expr, $value:expr) => {{
        let text = swift_json::to_sorted_pretty(&$value).expect("encode fixture");
        std::fs::write($project.path().join($name), text).expect("write fixture");
    }};
}

fn manifest(entity_count: i64) -> EditorSceneManifest {
    EditorSceneManifest::new(0, entity_count, Vec::new())
}

fn descriptor(schema_version: i64, entity_count: i64, scene_slot: i64) -> ProjectExportDescriptor {
    ProjectExportDescriptor::new(
        schema_version,
        "Fixture".to_string(),
        "2026-01-01T00:00:00Z".to_string(),
        entity_count,
        0,
        scene_slot,
    )
}

/// Development projects may omit a startup scene.
#[test]
fn development_project_may_have_no_scene() {
    let project = TemporaryProject::new("cove-player-scene");
    assert!(
        GameProjectSceneLoader::load(project.path())
            .expect("development project")
            .is_none()
    );
}

/// Exported projects load their declared scene.
#[test]
fn exported_project_loads_scene() {
    let project = TemporaryProject::new("cove-player-scene");
    let exported = manifest(2);
    ProjectExporter::export(&exported, "Demo", &[], None, None, None, project.path())
        .expect("export fixture");

    assert_eq!(
        GameProjectSceneLoader::load(project.path()).expect("exported scene"),
        Some(exported)
    );
}

/// An export descriptor without its declared scene is rejected.
#[test]
fn missing_exported_scene_fails() {
    let project = TemporaryProject::new("cove-player-scene");
    write_json!(
        project,
        "build.json",
        descriptor(
            ProjectExporter::SCHEMA_VERSION,
            1,
            ProjectExporter::SCENE_SLOT
        )
    );

    let error = GameProjectSceneLoader::load(project.path()).expect_err("missing scene");
    assert!(matches!(
        error,
        GameProjectSceneLoadError::MissingExportedScene(0)
    ));
}

/// Unsupported export descriptor versions are rejected.
#[test]
fn unsupported_export_version_fails() {
    let project = TemporaryProject::new("cove-player-scene");
    let version = ProjectExporter::SCHEMA_VERSION + 1;
    write_json!(
        project,
        "build.json",
        descriptor(version, 0, ProjectExporter::SCENE_SLOT)
    );

    let error = GameProjectSceneLoader::load(project.path()).expect_err("future export");
    assert!(matches!(
        error,
        GameProjectSceneLoadError::UnsupportedExportVersion(value) if value == version
    ));
}

/// Negative scene slots are rejected.
#[test]
fn invalid_scene_slot_fails() {
    let project = TemporaryProject::new("cove-player-scene");
    write_json!(
        project,
        "build.json",
        descriptor(ProjectExporter::SCHEMA_VERSION, 0, -1)
    );

    let error = GameProjectSceneLoader::load(project.path()).expect_err("invalid slot");
    assert!(matches!(
        error,
        GameProjectSceneLoadError::InvalidSceneSlot(-1)
    ));
}

/// The save at the declared slot must carry that slot.
#[test]
fn scene_slot_mismatch_fails() {
    let project = TemporaryProject::new("cove-player-scene");
    write_json!(
        project,
        "build.json",
        descriptor(
            ProjectExporter::SCHEMA_VERSION,
            2,
            ProjectExporter::SCENE_SLOT
        )
    );
    GameSaveDocument::new(1, manifest(2))
        .write(&GameSaveDocument::url(
            ProjectExporter::SCENE_SLOT,
            project.path(),
        ))
        .expect("scene save");

    let error = GameProjectSceneLoader::load(project.path()).expect_err("slot mismatch");
    assert!(matches!(
        error,
        GameProjectSceneLoadError::SceneSlotMismatch {
            expected: 0,
            actual: 1
        }
    ));
}

/// The descriptor's entity count must match the declared scene.
#[test]
fn entity_count_mismatch_fails() {
    let project = TemporaryProject::new("cove-player-scene");
    write_json!(
        project,
        "build.json",
        descriptor(
            ProjectExporter::SCHEMA_VERSION,
            1,
            ProjectExporter::SCENE_SLOT
        )
    );
    GameSaveDocument::new(ProjectExporter::SCENE_SLOT, manifest(2))
        .write(&GameSaveDocument::url(
            ProjectExporter::SCENE_SLOT,
            project.path(),
        ))
        .expect("scene save");

    let error = GameProjectSceneLoader::load(project.path()).expect_err("entity mismatch");
    assert!(matches!(
        error,
        GameProjectSceneLoadError::EntityCountMismatch {
            expected: 1,
            actual: 2
        }
    ));
}

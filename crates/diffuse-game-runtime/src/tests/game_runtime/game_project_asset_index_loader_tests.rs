//! Ported from `Editor/Tests/GameRuntimeTests/GameProjectAssetIndexLoaderTests.swift`.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use diffuse_assets::swift_json;
use diffuse_editor_core::scene::project_exporter::{
    ProjectExportAsset, ProjectExportAssetList, ProjectExportDescriptor, ProjectExporter,
};
use diffuse_kernel::codable::new_uuid;

use crate::game_project_asset_index_loader::{
    GameProjectAssetIndexError, GameProjectAssetIndexLoader,
};

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

fn asset(id: &str, relative_path: &str, kind: &str, mesh_index: i64) -> ProjectExportAsset {
    ProjectExportAsset::new(
        id.to_string(),
        id.to_string(),
        relative_path.to_string(),
        kind.to_string(),
        mesh_index,
    )
}

/// Missing asset list is valid for development projects.
#[test]
fn missing_list_is_empty() {
    let project = TemporaryProject::new("cove-player-assets");
    assert!(
        GameProjectAssetIndexLoader::load(project.path())
            .expect("development project")
            .is_empty()
    );
}

/// Loads stable mesh slots and ignores texture slot zero.
#[test]
fn loads_mesh_slots() {
    let project = TemporaryProject::new("cove-player-assets");
    write_json!(
        project,
        "assets.json",
        ProjectExportAssetList::new(vec![
            asset("mesh", "Assets\\ship.glb", "glb", 7),
            asset("texture", "tex.png", "png", 0),
        ])
    );

    let loaded = GameProjectAssetIndexLoader::load(project.path()).expect("asset index");
    assert_eq!(loaded, BTreeMap::from([("Assets/ship.glb".to_string(), 7)]));
}

/// An existing malformed asset list fails instead of silently remapping meshes.
#[test]
fn malformed_list_fails() {
    let project = TemporaryProject::new("cove-player-assets");
    std::fs::write(project.path().join("assets.json"), "not-json").expect("fixture");

    let error = GameProjectAssetIndexLoader::load(project.path()).expect_err("malformed list");
    assert!(matches!(error, GameProjectAssetIndexError::Decode(_)));
}

/// An export descriptor requires an asset list even when it is empty.
#[test]
fn exported_project_requires_asset_list() {
    let project = TemporaryProject::new("cove-player-assets");
    write_json!(
        project,
        "build.json",
        ProjectExportDescriptor::new(
            ProjectExporter::SCHEMA_VERSION,
            "Broken".to_string(),
            "2026-01-01T00:00:00Z".to_string(),
            0,
            0,
            ProjectExporter::SCENE_SLOT,
        )
    );

    let error = GameProjectAssetIndexLoader::load(project.path()).expect_err("missing list");
    assert!(matches!(
        error,
        GameProjectAssetIndexError::MissingExportAssetList
    ));
}

/// Duplicate mesh slots are rejected.
#[test]
fn duplicate_mesh_slots_fail() {
    let project = TemporaryProject::new("cove-player-assets");
    write_json!(
        project,
        "assets.json",
        ProjectExportAssetList::new(vec![
            asset("one", "one.glb", "glb", 4),
            asset("two", "two.glb", "glb", 4),
        ])
    );

    let error = GameProjectAssetIndexLoader::load(project.path()).expect_err("duplicate slot");
    assert!(matches!(
        error,
        GameProjectAssetIndexError::DuplicateMeshIndex(4)
    ));
}

/// The descriptor's asset count must describe the list exactly.
#[test]
fn asset_count_mismatch_fails() {
    let project = TemporaryProject::new("cove-player-assets");
    write_json!(
        project,
        "build.json",
        ProjectExportDescriptor::new(
            ProjectExporter::SCHEMA_VERSION,
            "Broken".to_string(),
            "2026-01-01T00:00:00Z".to_string(),
            1,
            2,
            ProjectExporter::SCENE_SLOT,
        )
    );
    write_json!(
        project,
        "assets.json",
        ProjectExportAssetList::new(vec![asset("one", "one.glb", "glb", 2)])
    );

    let error = GameProjectAssetIndexLoader::load(project.path()).expect_err("count mismatch");
    assert!(matches!(
        error,
        GameProjectAssetIndexError::AssetCountMismatch {
            expected: 2,
            actual: 1
        }
    ));
}

/// Unsafe relative paths are rejected with the original path.
#[test]
fn unsafe_relative_path_fails() {
    let project = TemporaryProject::new("cove-player-assets");
    write_json!(
        project,
        "assets.json",
        ProjectExportAssetList::new(vec![asset("one", "../escape.glb", "glb", 2)])
    );

    let error = GameProjectAssetIndexLoader::load(project.path()).expect_err("unsafe path");
    assert!(matches!(
        error,
        GameProjectAssetIndexError::UnsafeRelativePath(ref path) if path == "../escape.glb"
    ));
}

/// Duplicate relative paths are rejected even with distinct mesh slots.
#[test]
fn duplicate_relative_path_fails() {
    let project = TemporaryProject::new("cove-player-assets");
    write_json!(
        project,
        "assets.json",
        ProjectExportAssetList::new(vec![
            asset("one", "same.glb", "glb", 2),
            asset("two", "same.glb", "glb", 3),
        ])
    );

    let error = GameProjectAssetIndexLoader::load(project.path()).expect_err("duplicate path");
    assert!(matches!(
        error,
        GameProjectAssetIndexError::DuplicateRelativePath(ref path) if path == "same.glb"
    ));
}

//! `Editor/Tests/EditorCoreTests/EditorAssetFileWorkflowTests.swift`.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use cove_system::paths::PathIdentity;
use diffuse_assets::asset_registry::ImportableAssetKind;
use serde_json::{Value, json};

use crate::assets::asset_catalog::EditorAsset;
use crate::assets::asset_import_resolver::AssetImportResolver;
use crate::assets::editor_asset_file_workflow::{AssetFileWorkflowError, EditorAssetFileWorkflow};
use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::editor_inspector_schema::EditorInspectorFieldValue;

struct TempDirectory(PathBuf);

impl TempDirectory {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "cove-file-workflow-{}",
            diffuse_kernel::codable::new_uuid()
        ));
        fs::create_dir(&root).expect("temporary directory");
        Self(root)
    }

    fn write(&self, relative: &str, text: &str) -> PathBuf {
        let path = self.0.join(relative);
        fs::create_dir_all(path.parent().expect("parent path")).expect("parent directory");
        fs::write(&path, text).expect("fixture file");
        path
    }
}

impl Drop for TempDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn moving_a_model_preserves_dependencies_and_updates_scene_and_script_references() {
    let root = TempDirectory::new();
    let source = root.write(
        "Content/old/model.gltf",
        r#"{"buffers":[{"uri":"mesh.bin"}],"images":[{"uri":"textures/color.png"}]}"#,
    );
    let destination = root.0.join("Content/new/renamed.gltf");
    let original_mesh = root.write("Content/old/mesh.bin", "mesh");
    root.write("Content/old/textures/color.png", "image");
    let scene = root.write(
        ".cove/scene.json",
        &json!({"assetID": "Content/old/model.gltf", "absolutePath": source}).to_string(),
    );
    let script = root.write(
        "Scripts/spawn.rs",
        r#"let asset = "Content/old/model.gltf";"#,
    );
    let references = EditorAssetFileWorkflow::reference_files(&source, &root.0)
        .iter()
        .map(|file| PathIdentity::canonical_url(file))
        .collect::<BTreeSet<_>>();
    assert_eq!(
        references,
        [&scene, &script]
            .into_iter()
            .map(|file| PathIdentity::canonical_url(file))
            .collect()
    );

    EditorAssetFileWorkflow::relocate(&source, &destination, &root.0).expect("move model");

    assert!(!source.exists());
    assert!(destination.exists());
    assert_eq!(
        fs::read(root.0.join("Content/new/mesh.bin")).expect("copied mesh"),
        b"mesh"
    );
    assert!(original_mesh.exists());
    assert!(root.0.join("Content/new/textures/color.png").exists());
    let scene: Value =
        serde_json::from_slice(&fs::read(scene).expect("scene")).expect("scene JSON");
    assert_eq!(scene["assetID"], "Content/new/renamed.gltf");
    assert_eq!(scene["absolutePath"], json!(destination));
    assert_eq!(
        fs::read_to_string(script).expect("script"),
        r#"let asset = "Content/new/renamed.gltf";"#
    );
}

#[test]
fn moving_a_texture_rewrites_percent_encoded_gltf_uris() {
    let root = TempDirectory::new();
    let source = root.write("Content/textures/old color.png", "image");
    let destination = root.0.join("Content/shared/new color.png");
    let model = root.write(
        "Content/model.gltf",
        r#"{"images":[{"uri":"textures/old%20color.png"}]}"#,
    );

    EditorAssetFileWorkflow::relocate(&source, &destination, &root.0).expect("move texture");
    let model: Value =
        serde_json::from_slice(&fs::read(model).expect("model")).expect("model JSON");
    assert_eq!(model["images"][0]["uri"], "shared/new%20color.png");
}

#[test]
fn moving_a_texture_then_its_model_preserves_parent_relative_dependencies() {
    let root = TempDirectory::new();
    let model = root.write(
        "Content/Models/ship.gltf",
        r#"{"buffers":[{"uri":"../buffers/mesh.bin"}],"images":[{"uri":"textures/color.png"}]}"#,
    );
    let texture = root.write("Content/Models/textures/color.png", "image");
    let shared_texture = root.0.join("Content/shared/color.png");
    root.write("Content/buffers/mesh.bin", "buffer");
    EditorAssetFileWorkflow::relocate(&texture, &shared_texture, &root.0).expect("move texture");

    let moved_model = root.0.join("Scenes/new/ship.gltf");
    EditorAssetFileWorkflow::relocate(&model, &moved_model, &root.0).expect("move model");
    assert_eq!(
        fs::read(root.0.join("Scenes/shared/color.png")).expect("copied texture"),
        b"image"
    );
    assert_eq!(
        fs::read(root.0.join("Scenes/buffers/mesh.bin")).expect("copied mesh"),
        b"buffer"
    );
    assert!(shared_texture.exists());
    let files = AssetImportResolver::resolve(&moved_model, Some(&root.0));
    assert_eq!(
        files
            .iter()
            .map(|file| file.relative_path.as_str())
            .collect::<Vec<_>>(),
        ["ship.gltf", "../buffers/mesh.bin", "../shared/color.png"]
    );
    assert!(files.iter().all(|file| file.source.exists()));
}

#[test]
fn conflicting_dependencies_and_outside_destinations_preserve_the_source() {
    let root = TempDirectory::new();
    let source = root.write("old/model.gltf", r#"{"buffers":[{"uri":"mesh.bin"}]}"#);
    root.write("old/mesh.bin", "original");
    let conflicting = root.write("new/mesh.bin", "different");
    for target in ["new/model.gltf", "../escaped.gltf"] {
        assert!(EditorAssetFileWorkflow::relocate(&source, &root.0.join(target), &root.0).is_err());
    }
    assert!(source.exists());
    assert_eq!(
        fs::read_to_string(conflicting).expect("old contents"),
        "different"
    );
}

#[test]
fn restoring_a_missing_model_includes_dependencies_and_supports_binary_repair() {
    let root = TempDirectory::new();
    let source = root.write("external/model.gltf", r#"{"buffers":[{"uri":"mesh.bin"}]}"#);
    let buffer = root.write("external/mesh.bin", "buffer");
    let project = root.0.join("project");
    let target = project.join("Content/restored.gltf");
    EditorAssetFileWorkflow::restore_missing(&source, &target, &project, || Ok(()))
        .expect("restore model");
    assert!(target.exists());
    assert_eq!(
        fs::read(project.join("Content/mesh.bin")).expect("restored buffer"),
        b"buffer"
    );

    let repaired = project.join("Content/another.bin");
    EditorAssetFileWorkflow::restore_missing(&buffer, &repaired, &project, || Ok(()))
        .expect("restore binary dependency");
    assert!(repaired.exists());
}

#[test]
fn failed_validation_rolls_back_new_files_and_preserves_shared_dependencies() {
    let root = TempDirectory::new();
    let source = root.write(
        "external/model.gltf",
        r#"{"buffers":[{"uri":"shared.bin"},{"uri":"new.bin"}]}"#,
    );
    root.write("external/shared.bin", "shared");
    root.write("external/new.bin", "new");
    let shared = root.write("project/Content/shared.bin", "shared");
    let project = root.0.join("project");
    let target = project.join("Content/model.gltf");
    assert!(
        EditorAssetFileWorkflow::restore_missing(&source, &target, &project, || {
            Err(AssetFileWorkflowError::Failure("Invalid model".into()))
        })
        .is_err()
    );
    assert!(!target.exists());
    assert!(!project.join("Content/new.bin").exists());
    assert_eq!(fs::read(shared).expect("shared dependency"), b"shared");
}

#[test]
fn undo_and_redo_preserve_the_new_asset_identity() {
    let adapter = EditorSceneAdapter::with_defaults(false);
    let old = EditorAsset::new(
        "Content/old.glb",
        "Old",
        "Content/old.glb",
        "/project/Content/old.glb",
        ImportableAssetKind::Glb,
        0,
    );
    let new = EditorAsset::new(
        "Content/new.glb",
        "New",
        "Content/new.glb",
        "/project/Content/new.glb",
        ImportableAssetKind::Glb,
        0,
    );
    let entity = adapter
        .spawn_entity_from_asset_default(&old)
        .expect("spawn asset");
    let name = adapter
        .inspector_sections(Some(entity))
        .into_iter()
        .find(|section| section.id == "general")
        .and_then(|section| section.fields.into_iter().find(|field| field.id == "name"))
        .expect("name field");
    let EditorInspectorFieldValue::Text(binding) = name.value else {
        panic!("expected name binding");
    };
    binding.set("Edited name".into());
    adapter.relocate_asset_references(&old.id, &new);

    assert!(adapter.asset_referenced_entity_ids(&old.id).is_empty());
    assert_eq!(adapter.asset_referenced_entity_ids(&new.id), [entity]);
    assert!(adapter.undo_edit());
    assert_eq!(adapter.asset_referenced_entity_ids(&new.id), [entity]);
    assert!(adapter.redo_edit());
    assert_eq!(adapter.asset_referenced_entity_ids(&new.id), [entity]);
}

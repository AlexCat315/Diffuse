//! Ported from `Engine/Tests/AssetPipelineTests/AssetRegistryTests.swift`.

use diffuse_assets::asset_pipeline::{BuiltinMesh, MeshAsset};
use diffuse_assets::asset_registry::{AssetRegistry, ImportableAssetKind};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

fn temp_dir(tag: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
    let root = std::env::temp_dir().join(format!("asset-registry-{tag}-{nanos}"));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    root
}

fn append_f32(values: &[f32], out: &mut Vec<u8>) {
    for value in values {
        out.extend_from_slice(&value.to_le_bytes());
    }
}

fn append_u16(values: &[u16], out: &mut Vec<u8>) {
    for value in values {
        out.extend_from_slice(&value.to_le_bytes());
    }
}

/// Writes the Swift test's triangle glTF plus its sidecar buffer.
fn write_triangle_gltf(directory: &Path) {
    let mut buffer: Vec<u8> = Vec::new();
    append_f32(&[0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0, 0.0], &mut buffer);
    append_f32(&[0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0], &mut buffer);
    append_u16(&[0, 1, 2], &mut buffer);
    std::fs::write(directory.join("triangle.bin"), &buffer).unwrap();

    let json = r#"{
  "asset": { "version": "2.0" },
  "buffers": [
    { "uri": "triangle.bin", "byteLength": 78 }
  ],
  "bufferViews": [
    { "buffer": 0, "byteOffset": 0, "byteLength": 36 },
    { "buffer": 0, "byteOffset": 36, "byteLength": 36 },
    { "buffer": 0, "byteOffset": 72, "byteLength": 6 }
  ],
  "accessors": [
    { "bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3" },
    { "bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3" },
    { "bufferView": 2, "componentType": 5123, "count": 3, "type": "SCALAR" }
  ],
  "meshes": [
    {
      "primitives": [
        {
          "attributes": { "POSITION": 0, "NORMAL": 1 },
          "indices": 2
        }
      ]
    }
  ],
  "nodes": [
    { "mesh": 0 }
  ],
  "scenes": [
    { "nodes": [0] }
  ],
  "scene": 0
}"#;
    std::fs::write(directory.join("triangle.gltf"), json).unwrap();
}

// Explicit mesh registration survives project reload and can be removed independently.
#[test]
fn explicit_mesh_overlay_survives_reload() {
    let registry = AssetRegistry::new();
    let root = temp_dir("overlay");
    let mesh_index = 77;
    registry.register_for_testing(
        MeshAsset::new("transient", Vec::new(), Vec::new()),
        mesh_index,
    );
    let _ = registry
        .load_project_default(&root.to_string_lossy())
        .unwrap();
    assert_eq!(registry.mesh_asset(mesh_index).unwrap().name, "transient");
    assert!(
        registry
            .registered_meshes()
            .iter()
            .any(|registered| registered.mesh_index == mesh_index)
    );
    registry.unregister_testing_mesh(mesh_index);
    assert!(registry.mesh_asset(mesh_index).is_none());
    let _ = std::fs::remove_dir_all(&root);
}

// Scans the project directory and registers importable meshes.
#[test]
fn scans_project_directory() {
    let registry = AssetRegistry::new();
    let root = temp_dir("scan");
    let meshes = root.join("Assets/Meshes");
    let textures = root.join("Assets/Textures");
    std::fs::create_dir_all(&meshes).unwrap();
    std::fs::create_dir_all(&textures).unwrap();
    write_triangle_gltf(&meshes);
    std::fs::write(textures.join("smoke.png"), [0x89, 0x50, 0x4E, 0x47]).unwrap();
    std::fs::write(meshes.join("notes.txt"), "# ignore").unwrap();

    let entries = registry
        .load_project_default(&root.to_string_lossy())
        .unwrap();
    assert_eq!(entries.len(), 2);
    assert_eq!(entries[0].kind, ImportableAssetKind::Gltf);
    assert_eq!(
        entries[0].mesh_index,
        AssetRegistry::IMPORTED_MESH_START_INDEX
    );
    assert_eq!(entries[0].relative_path, "Assets/Meshes/triangle.gltf");
    assert_eq!(registry.entry(&entries[0].id), Some(entries[0].clone()));
    assert_eq!(
        registry.mesh_asset(entries[0].mesh_index).unwrap().name,
        "triangle.gltf"
    );
    assert_eq!(
        registry
            .registered_meshes()
            .iter()
            .map(|registered| registered.mesh_index)
            .collect::<Vec<_>>(),
        vec![AssetRegistry::IMPORTED_MESH_START_INDEX]
    );
    let expected_directory = meshes.canonicalize().unwrap();
    assert_eq!(
        registry.registered_meshes()[0].source_directory.as_deref(),
        Some(expected_directory.to_string_lossy().as_ref())
    );
    assert_eq!(entries[1].kind, ImportableAssetKind::Png);
    assert_eq!(entries[1].kind.scene_kind_label(), "Texture");
    assert!(entries[1].kind.is_texture());
    assert_eq!(entries[1].mesh_index, 0);
    assert_eq!(entries[1].relative_path, "Assets/Textures/smoke.png");
    assert_eq!(registry.entry(&entries[1].id), Some(entries[1].clone()));
    let _ = std::fs::remove_dir_all(&root);
}

// Honors persisted mesh indices from an export bundle.
#[test]
fn honors_preferred_mesh_index() {
    let registry = AssetRegistry::new();
    let root = temp_dir("preferred");
    let meshes = root.join("Assets/Meshes");
    std::fs::create_dir_all(&meshes).unwrap();
    write_triangle_gltf(&meshes);

    let mut preferred: BTreeMap<String, i64> = BTreeMap::new();
    preferred.insert("Assets/Meshes/triangle.gltf".to_string(), 17);
    let entries = registry
        .load_project(&root.to_string_lossy(), &preferred)
        .unwrap();
    assert_eq!(entries[0].mesh_index, 17);
    assert_eq!(
        registry
            .registered_meshes()
            .iter()
            .map(|registered| registered.mesh_index)
            .collect::<Vec<_>>(),
        vec![17]
    );
    let _ = std::fs::remove_dir_all(&root);
}

// Switching project roots never reuses a mesh from the previous project.
#[test]
fn isolates_project_roots() {
    let registry = AssetRegistry::new();
    let parent = temp_dir("roots");
    let first_meshes = parent.join("First/Assets/Meshes");
    let second_meshes = parent.join("Second/Assets/Meshes");
    std::fs::create_dir_all(&first_meshes).unwrap();
    std::fs::create_dir_all(&second_meshes).unwrap();
    write_triangle_gltf(&first_meshes);
    write_triangle_gltf(&second_meshes);

    registry
        .load_project_default(&parent.join("First").to_string_lossy())
        .unwrap();
    assert_eq!(
        registry.registered_meshes()[0].source_directory.as_deref(),
        Some(
            first_meshes
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .as_ref()
        )
    );

    registry
        .load_project_default(&parent.join("Second").to_string_lossy())
        .unwrap();
    assert_eq!(
        registry.registered_meshes()[0].source_directory.as_deref(),
        Some(
            second_meshes
                .canonicalize()
                .unwrap()
                .to_string_lossy()
                .as_ref()
        )
    );
    let _ = std::fs::remove_dir_all(&parent);
}

// Build directory matching is case-insensitive.
#[test]
fn ignores_build_directory_case_variants() {
    let registry = AssetRegistry::new();
    let root = temp_dir("build");
    let assets = root.join("Assets");
    let generated = root.join("Build");
    std::fs::create_dir_all(&assets).unwrap();
    std::fs::create_dir_all(&generated).unwrap();
    std::fs::write(assets.join("kept.png"), [1]).unwrap();
    std::fs::write(generated.join("ignored.png"), [2]).unwrap();

    let entries = registry
        .load_project_default(&root.to_string_lossy())
        .unwrap();
    assert_eq!(
        entries
            .iter()
            .map(|entry| entry.relative_path.clone())
            .collect::<Vec<_>>(),
        vec!["Assets/kept.png"]
    );
    let _ = std::fs::remove_dir_all(&root);
}

// Relocating a path keeps the mesh index assigned to it.
#[test]
fn relocate_keeps_index() {
    let registry = AssetRegistry::new();
    let root = temp_dir("relocate");
    let meshes = root.join("Assets/Meshes");
    std::fs::create_dir_all(&meshes).unwrap();
    write_triangle_gltf(&meshes);
    let entries = registry
        .load_project_default(&root.to_string_lossy())
        .unwrap();
    let index = entries[0].mesh_index;
    registry.relocate_asset_path("Assets/Meshes/triangle.gltf", "Assets/Meshes/renamed.gltf");
    std::fs::rename(meshes.join("triangle.gltf"), meshes.join("renamed.gltf")).unwrap();
    let reloaded = registry
        .load_project_default(&root.to_string_lossy())
        .unwrap();
    assert_eq!(reloaded[0].mesh_index, index);
    assert_eq!(reloaded[0].relative_path, "Assets/Meshes/renamed.gltf");
    let _ = std::fs::remove_dir_all(&root);
}

// An unknown project root is rejected with Swift's message.
#[test]
fn rejects_missing_project_root() {
    let registry = AssetRegistry::new();
    let missing = std::env::temp_dir().join("asset-registry-missing-root");
    let error = registry
        .load_project_default(&missing.to_string_lossy())
        .unwrap_err();
    assert_eq!(
        error.to_string(),
        format!("invalid project root: {}", missing.to_string_lossy())
    );
}

// Transient meshes do not disturb the file-backed catalog at other slots.
#[test]
fn transient_mesh_does_not_replace_other_slots() {
    let registry = AssetRegistry::new();
    let root = temp_dir("transient");
    let meshes = root.join("Assets");
    std::fs::create_dir_all(&meshes).unwrap();
    write_triangle_gltf(&meshes);
    let entries = registry
        .load_project_default(&root.to_string_lossy())
        .unwrap();
    let project_index = entries[0].mesh_index;
    registry.register_for_testing(BuiltinMesh::default_cube(), 90);
    assert_eq!(
        registry.mesh_asset(project_index).unwrap().name,
        "triangle.gltf"
    );
    assert_eq!(registry.mesh_asset(90).unwrap().name, "builtin.cube");
    registry.unregister_transient_mesh(90);
    assert_eq!(
        registry.mesh_asset(project_index).unwrap().name,
        "triangle.gltf"
    );
    let _ = std::fs::remove_dir_all(&root);
}

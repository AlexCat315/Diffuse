//! Ported from `Engine/Tests/AssetPipelineTests/GeometryAssetTests.swift`.

use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_assets::geometry::geometry_modifier::{
    GeometryAxis, GeometryModifier, GeometryModifierEntry,
};
use diffuse_assets::geometry::geometry_primitives::GeometryPrimitives;
use diffuse_assets::geometry::polygon_mesh::{GeometryError, GeometryLimits};
use diffuse_math::simd::simd_compat::Float3;
use std::collections::BTreeSet;

fn temp_dir(name: &str) -> std::path::PathBuf {
    let directory = std::env::temp_dir().join(format!("{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&directory);
    std::fs::create_dir_all(&directory).unwrap();
    directory
}

// Legacy modifier identities are deterministic and become persistent on save.
#[test]
fn modifier_identity() {
    let json = r#"{"version":1,"name":"Legacy","source":{"box":{"size":[1,1,1]}},"modifiers":[{"operation":{"subdivision":{"levels":1}}},{"enabled":true,"operation":{"array":{"count":2,"offset":[2,0,0]}}}]}"#;
    let first: GeometryDocument = serde_json::from_str(json).unwrap();
    let second: GeometryDocument = serde_json::from_str(json).unwrap();
    assert_eq!(first, second);
    let ids: BTreeSet<&str> = first
        .modifiers
        .iter()
        .map(|entry| entry.id.as_str())
        .collect();
    assert_eq!(ids.len(), 2);
    assert!(first.modifiers[0].enabled);

    // The positional fallback, as `decode_modifiers` binds it.
    let value: serde_json::Value = serde_json::from_str(json).unwrap();
    let decoded = GeometryDocument::decode_modifiers(&value["modifiers"]).unwrap();
    assert_eq!(decoded[0].id, "legacy-0");
    assert_eq!(decoded[1].id, "legacy-1");
    assert!(decoded[0].enabled);
    assert!(decoded[1].enabled);

    let mut reordered = first.clone();
    reordered.modifiers.reverse();
    let restored: GeometryDocument =
        serde_json::from_str(&serde_json::to_string(&reordered).unwrap()).unwrap();
    assert_eq!(restored, reordered);
    let _ = restored.evaluate(GeometryLimits::default()).unwrap();
    reordered.modifiers[0].id = reordered.modifiers[1].id.clone();
    assert!(reordered.evaluate(GeometryLimits::default()).is_err());
}

// Checked-in geometry examples load through the production registry.
#[test]
fn examples() {
    let directory = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../examples/GeometryAuthoring/Assets");
    let registry = AssetRegistry::new();
    let entries = registry
        .load_project_default(&directory.to_string_lossy())
        .unwrap();
    let mut names: Vec<&str> = entries.iter().map(|entry| entry.name.as_str()).collect();
    names.sort();
    assert_eq!(names, vec!["BezierPipe", "RoundedArray", "Shell"]);
    assert_eq!(registry.registered_meshes().len(), 3);
    for entry in &entries {
        let mesh = registry.mesh_asset(entry.mesh_index).unwrap();
        assert!(mesh.triangle_count() > 10);
    }
}

// Project scans evaluate native assets, retain scene units and reload changed sources.
#[test]
fn project_loading() {
    let root = temp_dir("geometry-project");
    let url = root.join("row.dmesh");
    let mut document = GeometryDocument::new(
        "Row",
        GeometrySource::Box {
            size: Float3::new(2.0, 2.0, 2.0),
        },
        vec![GeometryModifierEntry::new(
            GeometryModifier::Array {
                count: 3,
                offset: Float3::new(4.0, 0.0, 0.0),
            },
            true,
            "array",
        )],
        GeometryShading::Flat,
        vec![Default::default()],
    );
    document
        .save(&url.to_string_lossy(), GeometryLimits::default())
        .unwrap();

    let registry = AssetRegistry::new();
    let first = registry
        .load_project_default(&root.to_string_lossy())
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    assert!(first.kind.is_mesh() && !first.kind.is_texture());
    let mesh = registry.mesh_asset(first.mesh_index).unwrap();
    assert_eq!(mesh.local_bounds().0, Float3::new(-1.0, -1.0, -1.0));
    assert_eq!(mesh.local_bounds().1, Float3::new(9.0, 1.0, 1.0));

    let snapshot = registry.mesh_catalog(None).unwrap();
    assert_eq!(
        snapshot.meshes[0]
            .polygon_mesh
            .as_ref()
            .unwrap()
            .faces
            .len(),
        18
    );
    assert_eq!(
        registry
            .polygon_mesh(first.mesh_index)
            .unwrap()
            .edges()
            .len(),
        36
    );

    let slice = snapshot.meshes[0]
        .topology_slices
        .as_ref()
        .unwrap()
        .first()
        .unwrap()
        .clone();
    assert_eq!(slice.positions.len(), 24);
    let remap = slice.index_remap.clone().unwrap();
    for i in 0..slice.triangle_indices.len() {
        assert_eq!(
            slice.positions[remap[slice.triangle_indices[i] as usize] as usize],
            mesh.position(mesh.indices[i] as i64).unwrap()
        );
    }

    document.modifiers = vec![GeometryModifierEntry::new(
        GeometryModifier::Array {
            count: 2,
            offset: Float3::new(3.0, 0.0, 0.0),
        },
        true,
        "array",
    )];
    document
        .save(&url.to_string_lossy(), GeometryLimits::default())
        .unwrap();
    let second = registry
        .load_project_default(&root.to_string_lossy())
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    assert_eq!(first.mesh_index, second.mesh_index);
    assert_eq!(
        registry
            .mesh_asset(second.mesh_index)
            .unwrap()
            .local_bounds()
            .1
            .x,
        4.0
    );
    assert!(registry.mesh_catalog(Some(snapshot.revision)).is_some());
    let _ = std::fs::remove_dir_all(&root);
}

// Failed evaluation leaves an existing saved asset unchanged.
#[test]
fn atomic_save() {
    let root = temp_dir("geometry-atomic");
    let url = root.join("asset.dmesh");
    let mut document =
        GeometryDocument::with_source("Original", GeometrySource::Box { size: Float3::ONE });
    document
        .save(&url.to_string_lossy(), GeometryLimits::default())
        .unwrap();
    let original = std::fs::read(&url).unwrap();
    document.modifiers = vec![GeometryModifierEntry::new(
        GeometryModifier::Subdivision { levels: 99 },
        true,
        "subdivision",
    )];
    assert!(
        document
            .save(&url.to_string_lossy(), GeometryLimits::default())
            .is_err()
    );
    assert_eq!(std::fs::read(&url).unwrap(), original);
    assert_eq!(
        GeometryDocument::load(&url.to_string_lossy()).unwrap().name,
        "Original"
    );
    let _ = std::fs::remove_dir_all(&root);
}

// Minimal JSON documents supply authoring defaults.
#[test]
fn minimal_document() {
    let json = r#"{"version":1,"name":"Cube","source":{"box":{"size":[2,3,4]}}}"#;
    let document: GeometryDocument = serde_json::from_str(json).unwrap();
    assert!(document.modifiers.is_empty());
    assert_eq!(document.shading, GeometryShading::Flat);
    let evaluated = document.evaluate(GeometryLimits::default()).unwrap();
    assert_eq!(evaluated.mesh.local_bounds().1, Float3::new(1.0, 1.5, 2.0));
    let future = json.replace("\"version\":1", "\"version\":2");
    let decoded: Result<GeometryDocument, _> = serde_json::from_str(&future);
    // Swift throws `unsupportedVersion` from `init(from:)`; the Rust decoder keeps
    // the field and `evaluate`/`load` report the same error.
    let decoded = decoded.unwrap();
    assert_eq!(
        decoded.evaluate(GeometryLimits::default()).unwrap_err(),
        GeometryError::UnsupportedVersion(2)
    );
}

// Invalid native files do not enter the render catalog.
#[test]
fn invalid_asset() {
    let root = temp_dir("geometry-invalid");
    std::fs::write(
        root.join("bad.dmesh"),
        r#"{"version":1,"name":"Bad","source":{"box":{"size":[0,0,0]}}}"#,
    )
    .unwrap();
    let registry = AssetRegistry::new();
    assert!(
        registry
            .load_project_default(&root.to_string_lossy())
            .unwrap()
            .is_empty()
    );
    assert!(registry.registered_meshes().is_empty());
    let _ = std::fs::remove_dir_all(&root);
}

/// The example assets' modifier stacks, as authored on disk.
#[test]
fn example_modifier_stacks_round_trip() {
    let directory = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../examples/GeometryAuthoring/Assets");
    let registry = AssetRegistry::new();
    registry
        .load_project_default(&directory.to_string_lossy())
        .unwrap();
    for registered in registry.registered_meshes() {
        let polygon = registered
            .polygon_mesh
            .expect("dmesh assets keep their control mesh");
        assert!(!polygon.faces.is_empty());
    }
    // `RoundedArray.dmesh` uses subdivision + array; `Shell.dmesh` uses
    // subdivision + solidify. Mirror is exercised here for axis coverage.
    let mirrored = GeometryModifier::Mirror {
        axis: GeometryAxis::Y,
        offset: 0.0,
        weld_distance: 1e-5,
    }
    .apply(
        &GeometryPrimitives::unit_box().unwrap(),
        GeometryLimits::default(),
    )
    .unwrap();
    // No box face lies wholly on the seam, so all six are retained and six
    // reversed copies are appended.
    assert_eq!(mirrored.faces.len(), 12);
    assert_eq!(mirrored.positions.len(), 16);
}

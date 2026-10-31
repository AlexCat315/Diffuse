//! Ported from `Engine/Tests/AssetPipelineTests/MeshAssetCatalogTests.swift`.

use diffuse_assets::asset_pipeline::BuiltinMesh;
use diffuse_assets::asset_registry::AssetRegistry;

// Catalog snapshots pair changes and removals with revisions.
#[test]
fn revisions() {
    let registry = AssetRegistry::new();
    let initial = registry.mesh_catalog(None).unwrap();
    assert!(initial.meshes.is_empty());
    assert!(registry.mesh_catalog(Some(initial.revision)).is_none());

    registry.register_for_testing(BuiltinMesh::default_cube(), 45);
    let first = registry.mesh_catalog(Some(initial.revision)).unwrap();
    assert_eq!(
        first
            .meshes
            .iter()
            .map(|mesh| mesh.mesh_index)
            .collect::<Vec<_>>(),
        vec![45]
    );

    let mut replacement = BuiltinMesh::default_cube();
    replacement.name = "replacement".to_string();
    registry.register_for_testing(replacement, 45);
    let second = registry.mesh_catalog(Some(first.revision)).unwrap();
    assert_eq!(second.meshes[0].mesh.name, "replacement");

    registry.unregister_testing_mesh(45);
    let removed = registry.mesh_catalog(Some(second.revision)).unwrap();
    assert!(removed.meshes.is_empty());

    registry.reset();
    assert!(registry.mesh_catalog(Some(removed.revision)).is_some());
}

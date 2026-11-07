//! Ported from `Engine/Tests/AssetPipelineTests/DestructibleAssetBakerTests.swift`.

use std::collections::BTreeMap;

use diffuse_assets::{
    DestructibleAssetBakeError, DestructibleAssetBaker, PrefracturedFragmentInput,
};
use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_scene::components::core::registry::ComponentRegistry;
use diffuse_scene::physics::destruction::{DestructibleAssetResource, DestructibleConnectionAsset};
use diffuse_scene::physics::queries::spatial_queries::MeshColliderGeometryResource;
use diffuse_scene::runtime_world::LocalTransform;
use diffuse_scene::scene_runtime::SceneRuntime;

fn tetrahedron(fragment_id: u32) -> PrefracturedFragmentInput {
    PrefracturedFragmentInput::new(
        fragment_id,
        vec![
            Float3::new(0.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(0.0, 0.0, 1.0),
        ],
        vec![0, 2, 1, 0, 1, 3, 1, 2, 3, 2, 0, 3],
        LocalTransform::from_translation(Float3::new(fragment_id as f32, 0.0, 0.0)),
        6.0,
        u64::from(fragment_id) + 10,
        None,
        None,
    )
}

fn translated(fragment_id: u32, x: f32) -> PrefracturedFragmentInput {
    let mut fragment = tetrahedron(fragment_id);
    fragment.local_transform = LocalTransform::from_translation(Float3::new(x, 0.0, 0.0));
    fragment
}

fn runtime() -> SceneRuntime {
    SceneRuntime::new(ComponentRegistry::built_in())
}

/// "bakes stable convex IDs, volume masses, and a sorted connection graph"
#[test]
fn bake_and_install() {
    let result = DestructibleAssetBaker::new()
        .bake(
            "tower.fracture",
            4,
            &[tetrahedron(2), tetrahedron(0)],
            &[DestructibleConnectionAsset::new(9, 0, 2, 30.0, 0.0)],
            true,
            0.001,
        )
        .expect("bake");

    assert_eq!(result.asset.revision, 4);
    assert_eq!(
        result
            .asset
            .fragments
            .iter()
            .map(|fragment| fragment.fragment_id)
            .collect::<Vec<_>>(),
        vec![0, 2]
    );
    assert_eq!(
        result
            .asset
            .connections
            .iter()
            .map(|connection| connection.connection_id)
            .collect::<Vec<_>>(),
        vec![9]
    );
    assert_eq!(
        result
            .asset
            .fragments
            .iter()
            .map(|fragment| fragment.collider_resource_id.clone())
            .collect::<Vec<_>>(),
        vec![
            "tower.fracture#convex:0".to_string(),
            "tower.fracture#convex:2".to_string(),
        ]
    );
    assert!(
        result
            .asset
            .fragments
            .iter()
            .all(|fragment| (fragment.mass - 1.0).abs() < 0.0001)
    );
    assert_eq!(
        result
            .geometry_by_resource_id
            .get("tower.fracture#convex:0")
            .map(|geometry| geometry.revision),
        Some(10)
    );

    let mut scene = runtime();
    result.install(&mut scene);
    assert_eq!(
        scene
            .resource::<DestructibleAssetResource>()
            .and_then(|assets| assets.asset("tower.fracture").cloned()),
        Some(result.asset.clone())
    );
    assert_eq!(
        scene
            .resource::<MeshColliderGeometryResource>()
            .and_then(|geometries| geometries
                .geometry_for(Some("tower.fracture#convex:2"))
                .map(|geometry| geometry.positions.len())),
        Some(4)
    );
}

/// "rejects duplicate IDs, invalid graph endpoints, and zero-volume geometry"
#[test]
fn validation() {
    let baker = DestructibleAssetBaker::new();

    assert_eq!(
        baker
            .bake_fragments("duplicate", &[tetrahedron(0), tetrahedron(0)])
            .expect_err("duplicate fragment IDs"),
        DestructibleAssetBakeError::DuplicateFragmentID(0)
    );

    assert_eq!(
        baker
            .bake(
                "bad.graph",
                0,
                &[tetrahedron(0)],
                &[DestructibleConnectionAsset::new(3, 0, 8, 0.0, 0.0)],
                true,
                0.001,
            )
            .expect_err("invalid graph endpoint"),
        DestructibleAssetBakeError::InvalidConnection { connection_id: 3 }
    );

    let mut invalid_threshold = DestructibleConnectionAsset::new(4, 0, 1, 0.0, 0.0);
    invalid_threshold.impulse_threshold = f32::NAN;
    assert_eq!(
        baker
            .bake(
                "bad.threshold",
                0,
                &[tetrahedron(0), tetrahedron(1)],
                &[invalid_threshold],
                true,
                0.001,
            )
            .expect_err("NaN impulse threshold"),
        DestructibleAssetBakeError::InvalidConnection { connection_id: 4 }
    );

    let mut invalid_transform = tetrahedron(7);
    let mut matrix = MATRIX_IDENTITY_FLOAT4X4;
    matrix.columns[3].x = f32::NAN;
    invalid_transform.local_transform = LocalTransform::new(matrix);
    assert_eq!(
        baker
            .bake_fragments("bad.transform", &[invalid_transform])
            .expect_err("NaN transform"),
        DestructibleAssetBakeError::InvalidGeometry { fragment_id: 7 }
    );

    let flat = PrefracturedFragmentInput::with_geometry(
        5,
        vec![
            Float3::new(0.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
            Float3::new(1.0, 1.0, 0.0),
        ],
        vec![0, 1, 2, 1, 3, 2],
    );
    assert_eq!(
        baker
            .bake_fragments("flat", &[flat])
            .expect_err("flat geometry"),
        DestructibleAssetBakeError::NonClosedGeometry { fragment_id: 5 }
    );

    let mut open_tetrahedron = tetrahedron(6);
    open_tetrahedron.triangle_indices = vec![0, 2, 1, 0, 1, 3, 1, 2, 3];
    assert_eq!(
        baker
            .bake_fragments("open", &[open_tetrahedron])
            .expect_err("open tetrahedron"),
        DestructibleAssetBakeError::NonClosedGeometry { fragment_id: 6 }
    );

    assert_eq!(
        baker
            .bake(
                "bad.tolerance",
                0,
                &[tetrahedron(0)],
                &[],
                true,
                f32::NEG_INFINITY,
            )
            .expect_err("infinite tolerance"),
        DestructibleAssetBakeError::InvalidConnectionTolerance
    );
}

/// "generates a deterministic surface-adjacency graph unless explicitly disabled"
#[test]
fn automatic_connection_graph() {
    let left = translated(30, 0.0);
    let middle = translated(10, 1.0);
    let right = translated(20, 2.0);

    let baker = DestructibleAssetBaker::new();
    let first = baker
        .bake_fragments(
            "automatic.graph",
            &[right.clone(), left.clone(), middle.clone()],
        )
        .expect("first bake");
    let second = baker
        .bake_fragments("automatic.graph", &[middle.clone(), right, left.clone()])
        .expect("second bake");

    assert_eq!(first.asset.connections, second.asset.connections);
    assert_eq!(
        first
            .asset
            .connections
            .iter()
            .map(|connection| connection.connection_id)
            .collect::<Vec<_>>(),
        vec![0, 1]
    );
    assert_eq!(
        first
            .asset
            .connections
            .iter()
            .map(|connection| connection.fragment_a)
            .collect::<Vec<_>>(),
        vec![10, 10]
    );
    assert_eq!(
        first
            .asset
            .connections
            .iter()
            .map(|connection| connection.fragment_b)
            .collect::<Vec<_>>(),
        vec![20, 30]
    );

    let disabled = baker
        .bake("no.graph", 0, &[left, middle], &[], false, 0.001)
        .expect("disabled generation");
    assert!(disabled.asset.connections.is_empty());
}

/// "rejects a partially connected graph but permits an explicit edge-free asset"
#[test]
fn connection_graph_connectivity() {
    let left = translated(10, 0.0);
    let middle = translated(20, 1.0);
    let isolated = translated(30, 10.0);

    let baker = DestructibleAssetBaker::new();
    assert_eq!(
        baker
            .bake_fragments(
                "partially.connected",
                &[isolated.clone(), middle.clone(), left.clone()],
            )
            .expect_err("isolated fragment"),
        DestructibleAssetBakeError::DisconnectedConnectionGraph {
            fragment_ids: vec![30]
        }
    );

    let edge_free = baker
        .bake(
            "threshold.only",
            0,
            &[isolated, middle, left],
            &[],
            false,
            0.001,
        )
        .expect("edge-free asset");
    assert!(edge_free.asset.connections.is_empty());
}

/// "reinstalling a smaller bake removes only stale owned convex geometry"
#[test]
fn replacement_geometry_cleanup() {
    let baker = DestructibleAssetBaker::new();
    let initial = baker
        .bake(
            "replaceable",
            1,
            &[tetrahedron(1), tetrahedron(0)],
            &[],
            true,
            0.001,
        )
        .expect("initial bake");
    let mut surviving = tetrahedron(0);
    surviving.geometry_revision = 99;
    let replacement = baker
        .bake("replaceable", 2, &[surviving], &[], true, 0.001)
        .expect("replacement bake");

    let shared_geometry = initial
        .geometry_by_resource_id
        .get("replaceable#convex:0")
        .cloned()
        .expect("shared geometry");
    let mut scene = runtime();
    scene.set_resource(MeshColliderGeometryResource::new(
        BTreeMap::from([("shared.convex".to_string(), shared_geometry.clone())]),
        None,
    ));

    initial.install(&mut scene);
    replacement.install(&mut scene);

    let geometries = scene
        .resource::<MeshColliderGeometryResource>()
        .expect("geometries");
    assert_eq!(
        geometries
            .geometry_for(Some("replaceable#convex:0"))
            .map(|geometry| geometry.revision),
        Some(99)
    );
    assert!(
        geometries
            .geometry_for(Some("replaceable#convex:1"))
            .is_none()
    );
    assert_eq!(
        geometries.geometry_for(Some("shared.convex")),
        Some(&shared_geometry)
    );
    assert_eq!(
        scene
            .resource::<DestructibleAssetResource>()
            .and_then(|assets| assets.asset("replaceable").map(|asset| asset.revision)),
        Some(2)
    );
}

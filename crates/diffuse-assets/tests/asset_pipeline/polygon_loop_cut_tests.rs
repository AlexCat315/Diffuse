//! Ported from `Engine/Tests/AssetPipelineTests/PolygonLoopCutTests.swift`.

use diffuse_assets::asset_pipeline::MeshMaterial;
use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_primitives::GeometryPrimitives;
use diffuse_assets::geometry::polygon_mesh::{GeometryLimits, PolygonMesh, PolygonMeshEdge};
use diffuse_math::simd::simd_compat::{Float2, simd_cross, simd_distance2, simd_dot};
use std::collections::{BTreeMap, BTreeSet};

fn materials(count: usize) -> Vec<MeshMaterial> {
    vec![MeshMaterial::fallback(); count]
}

fn edge_counts(mesh: &PolygonMesh) -> BTreeMap<PolygonMeshEdge, i32> {
    let mut counts: BTreeMap<PolygonMeshEdge, i32> = BTreeMap::new();
    for face in &mesh.faces {
        for i in 0..face.vertices.len() {
            *counts
                .entry(PolygonMeshEdge::new(
                    face.vertices[i],
                    face.vertices[(i + 1) % face.vertices.len()],
                ))
                .or_insert(0) += 1;
        }
    }
    counts
}

fn volume(mesh: &PolygonMesh) -> f32 {
    let baked = mesh
        .bake(
            "volume",
            GeometryShading::Flat,
            &materials(1),
            GeometryLimits::default(),
        )
        .unwrap();
    let mut total = 0.0_f32;
    let mut i = 0;
    while i < baked.mesh.indices.len() {
        let a = baked.mesh.position(baked.mesh.indices[i] as i64).unwrap();
        let b = baked
            .mesh
            .position(baked.mesh.indices[i + 1] as i64)
            .unwrap();
        let c = baked
            .mesh
            .position(baked.mesh.indices[i + 2] as i64)
            .unwrap();
        total += simd_dot(a, simd_cross(b, c)) / 6.0;
        i += 3;
    }
    total.abs()
}

// Closed quad rings share vertices, keep old positions and produce spaced loops.
#[test]
fn closed_ring() {
    let original = GeometryPrimitives::unit_box().unwrap();
    let mut mesh = original.clone();
    let selected = mesh
        .loop_cut(
            PolygonMeshEdge::new(0, 1),
            3,
            0.0,
            GeometryLimits::default(),
        )
        .unwrap();
    assert_eq!(
        (mesh.positions.len(), mesh.faces.len(), selected.len()),
        (20, 18, 12)
    );
    assert_eq!(&mesh.positions[..8], &original.positions[..]);
    assert!(edge_counts(&mesh).values().all(|count| *count == 2));
    let mut xs: Vec<f32> = mesh.positions[8..].iter().map(|p| p.x).collect();
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap());
    xs.dedup();
    assert_eq!(xs, vec![-0.25, 0.0, 0.25]);
    for edge in &selected {
        assert_eq!(
            mesh.positions[edge.a as usize].x,
            mesh.positions[edge.b as usize].x
        );
    }
    assert!((volume(&mesh) - 1.0).abs() < 1e-5);
    mesh.bake_default("loops").unwrap();

    mesh.loop_cut(
        PolygonMeshEdge::new(0, 3),
        2,
        0.25,
        GeometryLimits::default(),
    )
    .unwrap();
    assert!(mesh.faces.iter().all(|face| face.vertices.len() == 4));
    assert!(edge_counts(&mesh).values().all(|count| *count == 2));
    assert!((volume(&mesh) - 1.0).abs() < 1e-5);
}

// Open strips preserve UV seams and material slots while slide moves every cut.
#[test]
fn strip() {
    let mut mesh =
        GeometryPrimitives::grid(Float2::new(2.0, 3.0), (1, 3), GeometryLimits::default()).unwrap();
    mesh.faces[1].material_index = 1;
    mesh.faces[1].uvs = mesh.faces[1]
        .uvs
        .as_ref()
        .map(|uvs| uvs.iter().map(|uv| *uv + Float2::new(2.0, 3.0)).collect());
    let old = mesh.clone();
    let selected = mesh
        .loop_cut(
            PolygonMeshEdge::new(0, 1),
            2,
            -0.5,
            GeometryLimits::default(),
        )
        .unwrap();
    assert_eq!(
        (mesh.positions.len(), mesh.faces.len(), selected.len()),
        (16, 9, 6)
    );
    assert_eq!(
        mesh.faces
            .iter()
            .filter(|face| face.material_index == 1)
            .count(),
        3
    );
    for face in &mesh.faces {
        for (i, index) in face.vertices.iter().enumerate() {
            let p = mesh.positions[*index as usize];
            let uv = face.uvs.as_ref().unwrap()[i];
            let offset = if face.material_index == 1 {
                Float2::new(2.0, 3.0)
            } else {
                Float2::ZERO
            };
            let expected = Float2::new((p.x + 1.0) / 2.0, (p.z + 1.5) / 3.0);
            assert!(simd_distance2(uv - offset, expected) < 1e-5);
        }
    }
    assert_eq!(&mesh.positions[..old.positions.len()], &old.positions[..]);
    mesh.bake(
        "strip",
        GeometryShading::Flat,
        &materials(2),
        GeometryLimits::default(),
    )
    .unwrap();
}

// Non-quads stop propagation and acquire edge points without T-junctions.
#[test]
fn terminal() {
    let mut mesh = GeometryPrimitives::unit_box().unwrap();
    mesh.triangulate_faces(&[1].iter().copied().collect(), GeometryLimits::default())
        .unwrap();
    let source = mesh.clone();
    let loops = mesh
        .loop_cut(
            PolygonMeshEdge::new(0, 1),
            1,
            0.0,
            GeometryLimits::default(),
        )
        .unwrap();
    assert_eq!(
        (loops.len(), mesh.positions.len(), mesh.faces.len()),
        (3, 12, 10)
    );
    assert!(edge_counts(&mesh).values().all(|count| *count == 2));
    assert!((volume(&mesh) - volume(&source)).abs() < 1e-5);
    mesh.bake_default("terminated").unwrap();
}

// Invalid counts, slide, geometry, UV mappings and budgets leave the asset intact.
#[test]
fn rejection() {
    let original = GeometryPrimitives::unit_box().unwrap();
    for count in [0_i64, -1, 65] {
        let mut mesh = original.clone();
        assert!(
            mesh.loop_cut(
                PolygonMeshEdge::new(0, 1),
                count,
                0.0,
                GeometryLimits::default()
            )
            .is_err()
        );
        assert_eq!(mesh, original);
    }
    for slide in [-1.0_f32, 1.0, f32::NAN, f32::INFINITY] {
        let mut mesh = original.clone();
        assert!(
            mesh.loop_cut(
                PolygonMeshEdge::new(0, 1),
                1,
                slide,
                GeometryLimits::default()
            )
            .is_err()
        );
        assert_eq!(mesh, original);
    }

    let mut nonplanar = original.clone();
    nonplanar.positions[0].z += 0.1;
    let mut uv = original.clone();
    if let Some(uvs) = uv.faces[0].uvs.as_mut() {
        uvs[1].x += 0.25;
    }
    let mut triangles = original.clone();
    let every: BTreeSet<i64> = (0..triangles.faces.len() as i64).collect();
    triangles
        .triangulate_faces(&every, GeometryLimits::default())
        .unwrap();
    for source in [nonplanar, uv, triangles] {
        let mut mesh = source.clone();
        assert!(
            mesh.loop_cut(
                PolygonMeshEdge::new(0, 1),
                1,
                0.0,
                GeometryLimits::default()
            )
            .is_err()
        );
        assert_eq!(mesh, source);
    }

    let mut mesh = original.clone();
    assert!(
        mesh.loop_cut(
            PolygonMeshEdge::new(0, 7),
            1,
            0.0,
            GeometryLimits::default()
        )
        .is_err()
    );
    assert!(
        mesh.loop_cut(
            PolygonMeshEdge::new(0, 1),
            1,
            0.0,
            GeometryLimits::new(8, 24)
        )
        .is_err()
    );
    assert_eq!(mesh, original);
}

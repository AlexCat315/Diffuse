//! Ported from `Engine/Tests/AssetPipelineTests/PolygonInsetTests.swift`.

use diffuse_assets::asset_pipeline::MeshMaterial;
use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_primitives::GeometryPrimitives;
use diffuse_assets::geometry::polygon_mesh::{
    GeometryLimits, PolygonFace, PolygonMesh, PolygonMeshEdge,
};
use diffuse_math::simd::simd_compat::{Float2, Float3, simd_cross, simd_dot};
use std::collections::{BTreeMap, BTreeSet};

fn set(values: &[i64]) -> BTreeSet<i64> {
    values.iter().copied().collect()
}

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

// Equal-width borders preserve original boundaries, cap indices and corner attributes.
#[test]
fn border() {
    let mut mesh =
        GeometryPrimitives::grid(Float2::new(2.0, 2.0), (1, 1), GeometryLimits::default()).unwrap();
    mesh.faces[0].material_index = 3;
    let original = mesh.clone();
    mesh.inset(&set(&[0]), 0.25, GeometryLimits::default())
        .unwrap();
    assert_eq!(&mesh.positions[..4], &original.positions[..]);
    assert_eq!((mesh.positions.len(), mesh.faces.len()), (8, 5));
    assert!(
        mesh.faces
            .iter()
            .all(|face| face.material_index == 3 && face.uvs.as_ref().unwrap().len() == 4)
    );
    for (index, vertex) in mesh.faces[0].vertices.iter().enumerate() {
        let p = mesh.positions[*vertex as usize];
        let uv = mesh.faces[0].uvs.as_ref().unwrap()[index];
        assert!((p.x.abs() - 0.75).abs() < 1e-6 && (p.z.abs() - 0.75).abs() < 1e-6);
        assert!(
            ((uv.x - 0.5).abs() - 0.375).abs() < 1e-6 && ((uv.y - 0.5).abs() - 0.375).abs() < 1e-6
        );
    }
    mesh.bake(
        "border",
        GeometryShading::Flat,
        &materials(4),
        GeometryLimits::default(),
    )
    .unwrap();
}

// Adjacent faces inset independently without breaking a closed manifold or its seams.
#[test]
fn closed() {
    let mut original = GeometryPrimitives::unit_box().unwrap();
    original.faces[1].uvs = original.faces[1]
        .uvs
        .as_ref()
        .map(|uvs| uvs.iter().map(|uv| *uv + Float2::new(2.0, 3.0)).collect());
    let mut mesh = original.clone();
    let every: BTreeSet<i64> = (0..mesh.faces.len() as i64).collect();
    mesh.inset(&every, 0.1, GeometryLimits::default()).unwrap();
    assert_eq!((mesh.positions.len(), mesh.faces.len()), (32, 30));
    assert_eq!(&mesh.positions[..8], &original.positions[..]);
    assert!(edge_counts(&mesh).values().all(|count| *count == 2));
    let shifted = mesh.faces[1].uvs.as_ref().unwrap();
    assert!(shifted.iter().all(|uv| uv.x > 2.0 && uv.y > 3.0));
    assert!((volume(&mesh) - 1.0).abs() < 1e-5);
}

// Inset then inward region extrusion forms a watertight recessed panel.
#[test]
fn recess() {
    let mut mesh = GeometryPrimitives::unit_box().unwrap();
    // Box face 1 points along +Z.
    mesh.inset(&set(&[1]), 0.1, GeometryLimits::default())
        .unwrap();
    mesh.extrude_faces(
        &set(&[1]),
        Float3::new(0.0, 0.0, -0.2),
        GeometryLimits::default(),
    )
    .unwrap();
    assert_eq!((mesh.positions.len(), mesh.faces.len()), (16, 14));
    assert!(edge_counts(&mesh).values().all(|count| *count == 2));
    assert!((volume(&mesh) - 0.872).abs() < 1e-5);
}

// Small faces get a usable default and collinear boundary vertices stay supported.
#[test]
fn defaults() {
    let mut mesh = PolygonMesh::new(
        vec![
            Float3::new(0.0, 0.0, 0.0),
            Float3::new(0.001, 0.0, 0.0),
            Float3::new(0.002, 0.0, 0.0),
            Float3::new(0.002, 0.001, 0.0),
            Float3::new(0.0, 0.001, 0.0),
        ],
        vec![PolygonFace::with_vertices(vec![0, 1, 2, 3, 4])],
    );
    let width = mesh
        .suggested_inset_distance(&set(&[0]), 0.1, GeometryLimits::default())
        .unwrap();
    assert!(width > 0.0 && width < 0.0005);
    mesh.inset(&set(&[0]), width, GeometryLimits::default())
        .unwrap();
    assert_eq!((mesh.positions.len(), mesh.faces.len()), (10, 6));
    mesh.bake_default("tiny").unwrap();

    let mut chamfer = PolygonMesh::new(
        vec![
            Float3::new(0.0, 0.0, 0.0),
            Float3::new(1.0, 0.0, 0.0),
            Float3::new(1.0, 0.99, 0.0),
            Float3::new(0.99, 1.0, 0.0),
            Float3::new(0.0, 1.0, 0.0),
        ],
        vec![PolygonFace::with_vertices(vec![0, 1, 2, 3, 4])],
    );
    let width = chamfer
        .suggested_inset_distance(&set(&[0]), 0.1, GeometryLimits::default())
        .unwrap();
    chamfer
        .inset(&set(&[0]), width, GeometryLimits::default())
        .unwrap();
    chamfer.bake_default("chamfer").unwrap();
}

// Invalid widths, unsupported surfaces and growth limits leave the source untouched.
#[test]
fn rejection() {
    let source = GeometryPrimitives::unit_box().unwrap();
    for width in [0.0_f32, -1.0, f32::NAN, f32::INFINITY, 0.5, 0.6] {
        let mut mesh = source.clone();
        assert!(
            mesh.inset(&set(&[0]), width, GeometryLimits::default())
                .is_err()
        );
        assert_eq!(mesh, source);
    }
    let mut folded = source.clone();
    folded.positions[0].z += 0.1;
    let mut uv = source.clone();
    if let Some(uvs) = uv.faces[0].uvs.as_mut() {
        uvs[1].x += 0.1;
    }
    let concave = PolygonMesh::new(
        vec![
            Float3::new(0.0, 0.0, 0.0),
            Float3::new(2.0, 0.0, 0.0),
            Float3::new(1.0, 1.0, 0.0),
            Float3::new(2.0, 2.0, 0.0),
            Float3::new(0.0, 2.0, 0.0),
        ],
        vec![PolygonFace::with_vertices(vec![0, 1, 2, 3, 4])],
    );
    for original in [folded, uv, concave] {
        let mut mesh = original.clone();
        assert!(
            mesh.inset(&set(&[0]), 0.1, GeometryLimits::default())
                .is_err()
        );
        assert_eq!(mesh, original);
    }
    let mut mesh = source.clone();
    assert!(
        mesh.inset(&set(&[99]), 0.1, GeometryLimits::default())
            .is_err()
    );
    assert!(
        mesh.inset(&set(&[0]), 0.1, GeometryLimits::new(8, 24))
            .is_err()
    );
    assert_eq!(mesh, source);
}

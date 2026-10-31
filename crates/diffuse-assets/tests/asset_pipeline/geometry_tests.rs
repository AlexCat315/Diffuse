//! Ported from `Engine/Tests/AssetPipelineTests/GeometryTests.swift`.

use diffuse_assets::asset_pipeline::MeshAsset;
use diffuse_assets::geometry::bezier_spline::{BezierControlPoint, BezierSpline, TubeParameters};
use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_modifier::GeometryModifier;
use diffuse_assets::geometry::geometry_primitives::GeometryPrimitives;
use diffuse_assets::geometry::polygon_mesh::{
    GeometryError, GeometryLimits, PolygonFace, PolygonMesh,
};
use diffuse_math::simd::simd_compat::{Float2, Float3, simd_cross, simd_dot, simd_length};
use std::collections::BTreeSet;

fn v3(x: f32, y: f32, z: f32) -> Float3 {
    Float3::new(x, y, z)
}

fn set(items: &[i64]) -> BTreeSet<i64> {
    items.iter().copied().collect()
}

/// Edge use counts and winding balance, mirroring the Swift `expectClosed`.
fn expect_closed(mesh: &PolygonMesh) {
    let mut edges: std::collections::BTreeMap<(i64, i64), (i32, i32)> = Default::default();
    for face in &mesh.faces {
        for i in 0..face.vertices.len() {
            let a = face.vertices[i];
            let b = face.vertices[(i + 1) % face.vertices.len()];
            let key = (a.min(b), a.max(b));
            let entry = edges.entry(key).or_insert((0, 0));
            entry.0 += 1;
            entry.1 += if a < b { 1 } else { -1 };
        }
    }
    assert!(
        edges
            .values()
            .all(|(count, direction)| *count == 2 && *direction == 0),
        "surface is not closed"
    );
}

fn signed_volume(mesh: &MeshAsset) -> f32 {
    let mut sum = 0.0_f32;
    let mut i = 0;
    while i < mesh.indices.len() {
        let a = mesh.position(mesh.indices[i] as i64).unwrap();
        let b = mesh.position(mesh.indices[i + 1] as i64).unwrap();
        let c = mesh.position(mesh.indices[i + 2] as i64).unwrap();
        sum += simd_dot(a, simd_cross(b, c)) / 6.0;
        i += 3;
    }
    sum
}

fn expect_frames(mesh: &MeshAsset) {
    assert!(mesh.vertices.iter().all(|value| value.is_finite()));
    for i in 0..mesh.vertex_count() {
        let base = i * MeshAsset::VERTEX_FLOAT_COUNT;
        let n = v3(
            mesh.vertices[base + 3],
            mesh.vertices[base + 4],
            mesh.vertices[base + 5],
        );
        let t = v3(
            mesh.vertices[base + 11],
            mesh.vertices[base + 12],
            mesh.vertices[base + 13],
        );
        assert!((simd_length(n) - 1.0).abs() < 1e-5);
        assert!((simd_length(t) - 1.0).abs() < 1e-5);
        assert!(simd_dot(n, t).abs() < 1e-5);
    }
}

fn straight_spline() -> BezierSpline {
    BezierSpline::new(
        vec![
            BezierControlPoint::new(Float3::ZERO, Float3::ZERO, v3(0.0, 0.0, 2.0 / 3.0)),
            BezierControlPoint::new(
                v3(0.0, 0.0, 2.0),
                v3(0.0, 0.0, 4.0 / 3.0),
                v3(0.0, 0.0, 2.0),
            ),
        ],
        false,
    )
}

// Catmull-Clark uses shared control vertices and preserves its source.
#[test]
fn subdivision() {
    let source = GeometryPrimitives::unit_box().unwrap();
    let result = GeometryModifier::Subdivision { levels: 1 }
        .apply(&source, GeometryLimits::default())
        .unwrap();
    assert_eq!((source.positions.len(), source.faces.len()), (8, 6));
    assert_eq!((result.positions.len(), result.faces.len()), (26, 24));
    assert!(simd_length(result.positions[0] - Float3::splat(-5.0 / 18.0)) < 1e-6);
    let second = GeometryModifier::Subdivision { levels: 1 }
        .apply(&result, GeometryLimits::default())
        .unwrap();
    assert_eq!((second.positions.len(), second.faces.len()), (98, 96));
    expect_closed(&second);
    let baked = second
        .bake(
            "rounded",
            GeometryShading::Smooth,
            &[diffuse_assets::asset_pipeline::MeshMaterial::fallback()],
            GeometryLimits::default(),
        )
        .unwrap();
    assert_eq!(baked.mesh.triangle_count(), 192);
    expect_frames(&baked.mesh);
}

// Open subdivision uses the boundary rule and interpolates corner UVs.
#[test]
fn boundary_subdivision() {
    let grid =
        GeometryPrimitives::grid(Float2::new(1.0, 1.0), (1, 1), GeometryLimits::default()).unwrap();
    let result = GeometryModifier::Subdivision { levels: 1 }
        .apply(&grid, GeometryLimits::default())
        .unwrap();
    assert_eq!(result.positions[0], v3(-0.375, 0.0, -0.375));
    assert_eq!(result.faces.len(), 4);
    assert_eq!(
        result.faces[0].uvs,
        Some(vec![
            Float2::new(0.0, 0.0),
            Float2::new(0.0, 0.5),
            Float2::new(0.5, 0.5),
            Float2::new(0.5, 0.0),
        ])
    );
    let _ = result.bake_default("patch").unwrap();
}

// Solidify closes every boundary and has the expected volume.
#[test]
fn shell() {
    let grid =
        GeometryPrimitives::grid(Float2::new(2.0, 2.0), (2, 2), GeometryLimits::default()).unwrap();
    let result = GeometryModifier::Solidify { thickness: 0.2 }
        .apply(&grid, GeometryLimits::default())
        .unwrap();
    expect_closed(&result);
    let baked = result
        .bake(
            "shell",
            GeometryShading::Flat,
            &[diffuse_assets::asset_pipeline::MeshMaterial::fallback()],
            GeometryLimits::default(),
        )
        .unwrap();
    assert!((signed_volume(&baked.mesh) - 0.8).abs() < 1e-5);
    assert_eq!(baked.mesh.local_bounds().0.y, -0.1);
    assert_eq!(baked.mesh.local_bounds().1.y, 0.1);
}

// Mirror welds only the plane seam and reverses face winding.
#[test]
fn mirror() {
    let half = PolygonMesh::new(
        vec![
            v3(0.0, 0.0, -1.0),
            v3(0.0, 0.0, 1.0),
            v3(1.0, 0.0, 1.0),
            v3(1.0, 0.0, -1.0),
        ],
        vec![PolygonFace::with_vertices(vec![0, 1, 2, 3])],
    );
    let result = GeometryModifier::Mirror {
        axis: diffuse_assets::geometry::geometry_modifier::GeometryAxis::X,
        offset: 0.0,
        weld_distance: 1e-5,
    }
    .apply(&half, GeometryLimits::default())
    .unwrap();
    assert_eq!((result.positions.len(), result.faces.len()), (6, 2));
    let baked = result
        .bake(
            "symmetric",
            GeometryShading::Flat,
            &[diffuse_assets::asset_pipeline::MeshMaterial::fallback()],
            GeometryLimits::default(),
        )
        .unwrap();
    for i in 0..baked.mesh.vertex_count() {
        assert!(
            baked.mesh.vertices
                [i * MeshAsset::VERTEX_FLOAT_COUNT + MeshAsset::NORMAL_FLOAT_OFFSET + 1]
                > 0.99
        );
    }
    let shell = GeometryModifier::Solidify { thickness: 0.2 }
        .apply(&result, GeometryLimits::default())
        .unwrap();
    expect_closed(&shell);
}

// Array keeps material slots and uses absolute scene offsets.
#[test]
fn array() {
    let mut source = GeometryPrimitives::unit_box().unwrap();
    source.faces[1].material_index = 1;
    let result = GeometryModifier::Array {
        count: 3,
        offset: v3(2.0, 0.0, 0.0),
    }
    .apply(&source, GeometryLimits::default())
    .unwrap();
    let materials = vec![
        diffuse_assets::asset_pipeline::MeshMaterial::fallback(),
        diffuse_assets::asset_pipeline::MeshMaterial::fallback(),
    ];
    let baked = result
        .bake(
            "row",
            GeometryShading::Flat,
            &materials,
            GeometryLimits::default(),
        )
        .unwrap();
    assert_eq!(baked.mesh.local_bounds().0.x, -0.5);
    assert_eq!(baked.mesh.local_bounds().1.x, 4.5);
    assert_eq!(
        result
            .faces
            .iter()
            .filter(|face| face.material_index == 1)
            .count(),
        3
    );
    assert!(
        baked
            .mesh
            .submeshes
            .iter()
            .any(|submesh| submesh.material_index == 1)
    );
    expect_closed(&result);
}

// Face extrusion and vertex edits are transactional.
#[test]
fn editing() {
    let mut mesh = GeometryPrimitives::unit_box().unwrap();
    mesh.extrude_face(3, v3(0.0, 1.0, 0.0), GeometryLimits::default())
        .unwrap();
    assert_eq!((mesh.positions.len(), mesh.faces.len()), (12, 10));
    expect_closed(&mesh);
    let extruded = mesh
        .bake(
            "extruded",
            GeometryShading::Flat,
            &[diffuse_assets::asset_pipeline::MeshMaterial::fallback()],
            GeometryLimits::default(),
        )
        .unwrap();
    assert!((signed_volume(&extruded.mesh) - 2.0).abs() < 1e-6);
    let previous = mesh.clone();
    assert!(
        mesh.translate(
            &set(&[0, 999]),
            v3(1.0, 0.0, 0.0),
            GeometryLimits::default()
        )
        .is_err()
    );
    assert_eq!(mesh, previous);
    assert!(
        mesh.extrude_face(0, v3(0.0, 1.0, 0.0), GeometryLimits::new(12, 1_000_000))
            .is_err()
    );
    assert_eq!(mesh, previous);
    mesh.translate(&set(&[0]), v3(0.1, 0.0, 0.0), GeometryLimits::default())
        .unwrap();
    assert_eq!(mesh.positions[0].x, previous.positions[0].x + 0.1);
}

// Concave polygons triangulate without filling their cutout.
#[test]
fn concave_polygon() {
    let shape = PolygonMesh::new(
        vec![
            v3(0.0, 0.0, 0.0),
            v3(2.0, 0.0, 0.0),
            v3(2.0, 1.0, 0.0),
            v3(1.0, 1.0, 0.0),
            v3(1.0, 2.0, 0.0),
            v3(0.0, 2.0, 0.0),
        ],
        vec![PolygonFace::with_vertices(vec![0, 1, 2, 3, 4, 5])],
    );
    let result = result_of(&shape, "L");
    let mut area = 0.0_f32;
    let mut i = 0;
    while i < result.mesh.indices.len() {
        let a = result.mesh.position(result.mesh.indices[i] as i64).unwrap();
        let b = result
            .mesh
            .position(result.mesh.indices[i + 1] as i64)
            .unwrap();
        let c = result
            .mesh
            .position(result.mesh.indices[i + 2] as i64)
            .unwrap();
        area += simd_cross(b - a, c - a).z * 0.5;
        let center = (a + b + c) / 3.0;
        assert!(center.x <= 1.0 || center.y <= 1.0);
        i += 3;
    }
    assert_eq!(result.mesh.triangle_count(), 4);
    assert!((area - 3.0).abs() < 1e-6);
}

fn result_of(
    mesh: &PolygonMesh,
    name: &str,
) -> diffuse_assets::geometry::geometry_baker::GeometryEvaluation {
    mesh.bake(
        name,
        GeometryShading::Flat,
        &[diffuse_assets::asset_pipeline::MeshMaterial::fallback()],
        GeometryLimits::default(),
    )
    .unwrap()
}

// Invalid topology, parameters, versions and growth fail predictably.
#[test]
fn validation() {
    let source = GeometryPrimitives::unit_box().unwrap();
    assert_eq!(
        GeometryModifier::Array {
            count: i64::MAX,
            offset: Float3::ZERO
        }
        .apply(&source, GeometryLimits::default())
        .unwrap_err(),
        GeometryError::BudgetExceeded
    );
    assert_eq!(
        GeometryModifier::Subdivision { levels: 3 }
            .apply(&source, GeometryLimits::new(100, 1_000_000))
            .unwrap_err(),
        GeometryError::BudgetExceeded
    );
    assert!(
        GeometryModifier::Solidify {
            thickness: f32::NAN
        }
        .apply(&source, GeometryLimits::default())
        .is_err()
    );
    let mut bad = source.clone();
    bad.positions[0].x = f32::INFINITY;
    assert!(bad.bake_default("bad").is_err());
    bad = source.clone();
    bad.faces[0].vertices[0] = -1;
    assert!(bad.bake_default("bad").is_err());
    bad = source.clone();
    bad.faces.push(bad.faces[0].clone());
    assert!(
        GeometryModifier::Subdivision { levels: 1 }
            .apply(&bad, GeometryLimits::default())
            .is_err()
    );
    let bow_tie_vertex = PolygonMesh::new(
        vec![
            v3(0.0, 0.0, 0.0),
            v3(1.0, 0.0, 0.0),
            v3(0.0, 1.0, 0.0),
            v3(-1.0, 0.0, 0.0),
            v3(0.0, -1.0, 0.0),
        ],
        vec![
            PolygonFace::with_vertices(vec![0, 1, 2]),
            PolygonFace::with_vertices(vec![0, 3, 4]),
        ],
    );
    assert!(
        GeometryModifier::Subdivision { levels: 1 }
            .apply(&bow_tie_vertex, GeometryLimits::default())
            .is_err()
    );
    assert!(
        GeometryModifier::Solidify { thickness: 1.0 }
            .apply(&bow_tie_vertex, GeometryLimits::default())
            .is_err()
    );
    let mut document = diffuse_assets::geometry::geometry_document::GeometryDocument::with_source(
        "future",
        diffuse_assets::geometry::geometry_document::GeometrySource::Box { size: Float3::ONE },
    );
    document.version = 999;
    assert_eq!(
        document.evaluate(GeometryLimits::default()).unwrap_err(),
        GeometryError::UnsupportedVersion(999)
    );
    let bow_tie = PolygonMesh::new(
        vec![
            v3(0.0, 0.0, 0.0),
            v3(1.0, 1.0, 0.0),
            v3(0.0, 1.0, 0.0),
            v3(1.0, 0.0, 0.0),
        ],
        vec![PolygonFace::with_vertices(vec![0, 1, 2, 3])],
    );
    assert!(bow_tie.bake_default("crossing").is_err());
}

// Bake retains a map between welded topology and split GPU corners.
#[test]
fn topology_map() {
    let result = result_of(&GeometryPrimitives::unit_box().unwrap(), "cube");
    assert_eq!(result.mesh.vertex_count(), 24);
    assert_eq!(result.topology_slice.positions.len(), 8);
    let remap = result
        .topology_slice
        .index_remap
        .clone()
        .expect("index remap is present");
    assert_eq!(remap.len(), result.mesh.vertex_count());
    for (index, mapped) in remap.iter().enumerate() {
        assert_eq!(
            result.mesh.position(index as i64),
            Some(result.topology_slice.positions[*mapped as usize])
        );
    }
    for i in 0..result.mesh.indices.len() {
        assert_eq!(
            result.mesh.indices[i],
            result.topology_slice.triangle_indices[i]
        );
    }
    expect_frames(&result.mesh);
}

// Bezier tube has outward winding, caps and stable frames.
#[test]
fn tube() {
    let spline = straight_spline();
    assert_eq!(spline.position(0, 0.5).unwrap(), v3(0.0, 0.0, 1.0));
    let result = spline
        .tube(
            TubeParameters {
                radius: 0.25,
                radial_segments: 8,
                samples_per_segment: 4,
                capped: true,
            },
            GeometryLimits::default(),
        )
        .unwrap();
    assert_eq!((result.positions.len(), result.faces.len()), (40, 34));
    expect_closed(&result);
    let baked = result
        .bake(
            "pipe",
            GeometryShading::Smooth,
            &[diffuse_assets::asset_pipeline::MeshMaterial::fallback()],
            GeometryLimits::default(),
        )
        .unwrap();
    assert!((signed_volume(&baked.mesh) - 0.353_553_4).abs() < 1e-5);
    expect_frames(&baked.mesh);
    assert_eq!(
        spline
            .tube(
                TubeParameters {
                    radius: 1.0,
                    radial_segments: 256,
                    samples_per_segment: 4096,
                    capped: true,
                },
                GeometryLimits::new(100, 1_000_000),
            )
            .unwrap_err(),
        GeometryError::BudgetExceeded
    );
    let vertical = BezierSpline::new(
        vec![
            BezierControlPoint::new(Float3::ZERO, Float3::ZERO, v3(0.0, 1.0, 0.0)),
            BezierControlPoint::new(v3(0.0, 3.0, 0.0), v3(0.0, 2.0, 0.0), v3(0.0, 3.0, 0.0)),
        ],
        false,
    );
    let vertical_mesh = vertical
        .tube(TubeParameters::new(0.2), GeometryLimits::default())
        .unwrap()
        .bake(
            "vertical",
            GeometryShading::Smooth,
            &[diffuse_assets::asset_pipeline::MeshMaterial::fallback()],
            GeometryLimits::default(),
        )
        .unwrap();
    expect_frames(&vertical_mesh.mesh);
}

// Closed spline sweep connects its last ring without caps.
#[test]
fn closed_tube() {
    let k: f32 = 0.552_284_8;
    let spline = BezierSpline::new(
        vec![
            BezierControlPoint::new(v3(1.0, 0.0, 0.0), v3(1.0, -k, 0.0), v3(1.0, k, 0.0)),
            BezierControlPoint::new(v3(0.0, 1.0, 0.0), v3(k, 1.0, 0.0), v3(-k, 1.0, 0.0)),
            BezierControlPoint::new(v3(-1.0, 0.0, 0.0), v3(-1.0, k, 0.0), v3(-1.0, -k, 0.0)),
            BezierControlPoint::new(v3(0.0, -1.0, 0.0), v3(-k, -1.0, 0.0), v3(k, -1.0, 0.0)),
        ],
        true,
    );
    let mesh = spline
        .tube(
            TubeParameters {
                radius: 0.1,
                radial_segments: 8,
                samples_per_segment: 8,
                capped: true,
            },
            GeometryLimits::default(),
        )
        .unwrap();
    assert_eq!((mesh.positions.len(), mesh.faces.len()), (256, 256));
    expect_closed(&mesh);
    let baked = mesh
        .bake(
            "ring",
            GeometryShading::Smooth,
            &[diffuse_assets::asset_pipeline::MeshMaterial::fallback()],
            GeometryLimits::default(),
        )
        .unwrap();
    assert!(signed_volume(&baked.mesh) > 0.0);
    expect_frames(&baked.mesh);
}

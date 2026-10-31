//! Ported from `Engine/Tests/AssetPipelineTests/PolygonTopologyTests.swift`.

use diffuse_assets::asset_pipeline::MeshMaterial;
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_document::{
    GeometryDocument, GeometryMaterial, GeometrySource,
};
use diffuse_assets::geometry::geometry_modifier::{
    GeometryAxis, GeometryModifier, GeometryModifierEntry,
};
use diffuse_assets::geometry::geometry_primitives::GeometryPrimitives;
use diffuse_assets::geometry::polygon_mesh::{
    GeometryLimits, PolygonFace, PolygonMesh, PolygonMeshEdge,
};
use diffuse_math::simd::simd_compat::{Float2, Float3, simd_cross, simd_length};
use std::collections::{BTreeMap, BTreeSet};

fn set(values: &[i64]) -> BTreeSet<i64> {
    values.iter().copied().collect()
}

fn materials(count: usize) -> Vec<MeshMaterial> {
    vec![MeshMaterial::fallback(); count]
}

fn face_edges(face: &PolygonFace) -> BTreeSet<PolygonMeshEdge> {
    (0..face.vertices.len())
        .map(|i| {
            PolygonMeshEdge::new(
                face.vertices[i],
                face.vertices[(i + 1) % face.vertices.len()],
            )
        })
        .collect()
}

fn interior_edges(mesh: &PolygonMesh) -> BTreeSet<PolygonMeshEdge> {
    let mut counts: BTreeMap<PolygonMeshEdge, i32> = BTreeMap::new();
    for face in &mesh.faces {
        for edge in face_edges(face) {
            *counts.entry(edge).or_insert(0) += 1;
        }
    }
    counts
        .into_iter()
        .filter(|(_, count)| *count == 2)
        .map(|(edge, _)| edge)
        .collect()
}

fn area(mesh: &PolygonMesh) -> f32 {
    let baked = mesh
        .bake(
            "area",
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
        total += simd_length(simd_cross(b - a, c - a)) * 0.5;
        i += 3;
    }
    total
}

// Component deletion removes incident faces, compacts vertices and keeps retained data.
#[test]
fn deletion() {
    let source = GeometryPrimitives::unit_box().unwrap();

    let mut vertices = source.clone();
    vertices
        .delete(
            &set(&[0]),
            &BTreeSet::new(),
            &BTreeSet::new(),
            GeometryLimits::default(),
        )
        .unwrap();
    assert_eq!((vertices.faces.len(), vertices.positions.len()), (3, 7));
    assert!(!vertices.positions.contains(&source.positions[0]));
    assert_eq!(
        vertices
            .faces
            .iter()
            .map(|face| face.uvs.clone())
            .collect::<Vec<_>>(),
        vec![
            source.faces[1].uvs.clone(),
            source.faces[3].uvs.clone(),
            source.faces[5].uvs.clone()
        ]
    );

    let mut edges = source.clone();
    edges
        .delete(
            &BTreeSet::new(),
            &set_edges(&[(0, 1)]),
            &BTreeSet::new(),
            GeometryLimits::default(),
        )
        .unwrap();
    assert_eq!((edges.faces.len(), edges.positions.len()), (4, 8));

    let mut faces = source.clone();
    faces
        .delete(
            &BTreeSet::new(),
            &BTreeSet::new(),
            &set(&[1]),
            GeometryLimits::default(),
        )
        .unwrap();
    assert_eq!(
        faces.faces,
        source
            .faces
            .iter()
            .enumerate()
            .filter(|(index, _)| *index != 1)
            .map(|(_, face)| face.clone())
            .collect::<Vec<_>>()
    );

    for mesh in [&vertices, &edges, &faces] {
        let referenced: BTreeSet<i64> = mesh
            .faces
            .iter()
            .flat_map(|face| face.vertices.clone())
            .collect();
        assert_eq!(referenced.len(), mesh.positions.len());
        mesh.bake_default("deleted").unwrap();
    }

    let before = faces.clone();
    assert!(
        faces
            .delete(
                &set(&[-1]),
                &BTreeSet::new(),
                &BTreeSet::new(),
                GeometryLimits::default()
            )
            .is_err()
    );
    assert!(
        faces
            .delete(
                &BTreeSet::new(),
                &set_edges(&[(0, 6)]),
                &BTreeSet::new(),
                GeometryLimits::default()
            )
            .is_err()
    );
    assert!(
        faces
            .delete(
                &BTreeSet::new(),
                &BTreeSet::new(),
                &set(&[100]),
                GeometryLimits::default()
            )
            .is_err()
    );
    assert_eq!(faces, before);
}

fn set_edges(items: &[(i64, i64)]) -> BTreeSet<PolygonMeshEdge> {
    items
        .iter()
        .map(|(a, b)| PolygonMeshEdge::new(*a, *b))
        .collect()
}

// An empty authored asset survives modifiers, save and reload with its identity.
#[test]
fn empty_asset() {
    let mut mesh = GeometryPrimitives::unit_box().unwrap();
    let every: BTreeSet<i64> = (0..mesh.faces.len() as i64).collect();
    mesh.delete(
        &BTreeSet::new(),
        &BTreeSet::new(),
        &every,
        GeometryLimits::default(),
    )
    .unwrap();
    assert!(mesh.positions.is_empty() && mesh.faces.is_empty());

    let modifiers = vec![
        GeometryModifierEntry::new(
            GeometryModifier::Array {
                count: 3,
                offset: Float3::new(2.0, 0.0, 0.0),
            },
            true,
            "a",
        ),
        GeometryModifierEntry::new(GeometryModifier::Subdivision { levels: 2 }, true, "b"),
        GeometryModifierEntry::new(
            GeometryModifier::Mirror {
                axis: GeometryAxis::X,
                offset: 0.0,
                weld_distance: 1e-5,
            },
            true,
            "c",
        ),
        GeometryModifierEntry::new(GeometryModifier::Solidify { thickness: 0.1 }, true, "d"),
    ];
    let document = GeometryDocument::new(
        "empty",
        GeometrySource::Polygon { mesh: mesh.clone() },
        modifiers,
        GeometryShading::Flat,
        vec![GeometryMaterial::default()],
    );
    let evaluated = document.evaluate(GeometryLimits::default()).unwrap();
    assert_eq!(
        (
            evaluated.mesh.vertex_count(),
            evaluated.mesh.triangle_count()
        ),
        (0, 0)
    );
    assert_eq!(evaluated.mesh.local_bounds().0, Float3::ZERO);
    assert_eq!(evaluated.mesh.local_bounds().1, Float3::ZERO);
    assert!(evaluated.topology_slice.positions.is_empty());
    assert!(evaluated.topology_slice.triangle_indices.is_empty());

    assert!(
        GeometryModifier::Array {
            count: 0,
            offset: Float3::ZERO
        }
        .apply(&mesh, GeometryLimits::default())
        .is_err()
    );
    assert!(
        PolygonMesh::new(vec![Float3::ZERO], Vec::new())
            .validate(GeometryLimits::default())
            .is_err()
    );

    let root = std::env::temp_dir().join(format!("empty-geometry-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("surface.dmesh");
    GeometryDocument::with_source("filled", GeometrySource::Box { size: Float3::ONE })
        .save(&path.to_string_lossy(), GeometryLimits::default())
        .unwrap();
    let registry = AssetRegistry::new();
    let before = registry
        .load_project_default(&root.to_string_lossy())
        .unwrap()
        .remove(0);
    document
        .save(&path.to_string_lossy(), GeometryLimits::default())
        .unwrap();
    let after = registry
        .load_project_default(&root.to_string_lossy())
        .unwrap()
        .remove(0);
    assert_eq!((before.id, before.mesh_index), (after.id, after.mesh_index));
    assert_eq!(
        registry
            .mesh_asset(after.mesh_index)
            .unwrap()
            .triangle_count(),
        0
    );
    assert_eq!(
        GeometryDocument::load(&path.to_string_lossy()).unwrap(),
        document
    );
    let _ = std::fs::remove_dir_all(&root);
}

// Dissolving a triangulation restores the original quad and its corner attributes.
#[test]
fn triangulated_quad() {
    let source = GeometryPrimitives::unit_box().unwrap();
    let mut mesh = source.clone();
    let triangles = mesh
        .triangulate_faces(&set(&[1]), GeometryLimits::default())
        .unwrap();
    let first = *triangles.iter().min().unwrap();
    let last = *triangles.iter().max().unwrap();
    let common: BTreeSet<PolygonMeshEdge> = face_edges(&mesh.faces[first as usize])
        .intersection(&face_edges(&mesh.faces[last as usize]))
        .copied()
        .collect();
    assert_eq!(common.len(), 1);
    let merged = mesh.dissolve(&common, GeometryLimits::default()).unwrap();
    assert_eq!(merged, set(&[1]));
    assert_eq!(mesh, source);
}

// Connected coplanar regions remove internal vertices and retain concave outlines.
#[test]
fn regions() {
    let mut grid =
        GeometryPrimitives::grid(Float2::new(2.0, 2.0), (2, 2), GeometryLimits::default()).unwrap();
    grid.dissolve(&interior_edges(&grid), GeometryLimits::default())
        .unwrap();
    assert_eq!((grid.faces.len(), grid.positions.len()), (1, 8));
    assert!((area(&grid) - 4.0).abs() < 1e-5);

    let mut concave =
        GeometryPrimitives::grid(Float2::new(2.0, 2.0), (2, 2), GeometryLimits::default()).unwrap();
    concave
        .delete(
            &BTreeSet::new(),
            &BTreeSet::new(),
            &set(&[3]),
            GeometryLimits::default(),
        )
        .unwrap();
    concave
        .dissolve(&interior_edges(&concave), GeometryLimits::default())
        .unwrap();
    assert_eq!(concave.faces.len(), 1);
    assert!((area(&concave) - 3.0).abs() < 1e-5);
}

// UV seams, interpolation, materials, folds, holes and boundary edges cannot be dissolved.
#[test]
fn rejected_regions() {
    let source =
        GeometryPrimitives::grid(Float2::new(2.0, 1.0), (2, 1), GeometryLimits::default()).unwrap();
    let selection = interior_edges(&source);

    let mut variants: Vec<PolygonMesh> = Vec::new();
    let mut seam = source.clone();
    seam.faces[1].uvs = seam.faces[1]
        .uvs
        .as_ref()
        .map(|uvs| uvs.iter().map(|uv| *uv + Float2::new(0.25, 0.0)).collect());
    variants.push(seam);
    let mut mapping = source.clone();
    if let Some(uvs) = mapping.faces[1].uvs.as_mut() {
        uvs[2].y += 0.25;
    }
    variants.push(mapping);
    let mut material = source.clone();
    material.faces[1].material_index = 1;
    variants.push(material);
    let mut folded = source.clone();
    folded.positions[2].y = 1.0;
    variants.push(folded);
    let mut mixed = source.clone();
    mixed.faces[1].uvs = None;
    variants.push(mixed);

    for original in variants {
        let mut mesh = original.clone();
        assert!(
            mesh.dissolve(&selection, GeometryLimits::default())
                .is_err()
        );
        assert_eq!(mesh, original);
    }

    let mut boundary = source.clone();
    assert!(
        boundary
            .dissolve(&set_edges(&[(0, 1)]), GeometryLimits::default())
            .is_err()
    );
    assert_eq!(boundary, source);

    let mut ring =
        GeometryPrimitives::grid(Float2::new(3.0, 3.0), (3, 3), GeometryLimits::default()).unwrap();
    ring.delete(
        &BTreeSet::new(),
        &BTreeSet::new(),
        &set(&[4]),
        GeometryLimits::default(),
    )
    .unwrap();
    let original_ring = ring.clone();
    assert!(
        ring.dissolve(&interior_edges(&ring), GeometryLimits::default())
            .is_err()
    );
    assert_eq!(ring, original_ring);
}

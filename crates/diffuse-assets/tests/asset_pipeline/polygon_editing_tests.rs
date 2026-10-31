//! Ported from `Engine/Tests/AssetPipelineTests/PolygonEditingTests.swift`.

use diffuse_assets::asset_pipeline::MeshMaterial;
use diffuse_assets::asset_registry::AssetRegistry;
use diffuse_assets::geometry::geometry_baker::GeometryShading;
use diffuse_assets::geometry::geometry_document::{GeometryDocument, GeometrySource};
use diffuse_assets::geometry::geometry_primitives::GeometryPrimitives;
use diffuse_assets::geometry::polygon_mesh::{
    GeometryError, GeometryLimits, PolygonMesh, PolygonMeshEdge,
};
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, Float4x4};
use std::collections::{BTreeMap, BTreeSet};

fn set(values: &[i64]) -> BTreeSet<i64> {
    values.iter().copied().collect()
}

fn capability(limits: GeometryLimits) -> GeometryLimits {
    limits
}

fn edge_uses(mesh: &PolygonMesh) -> BTreeMap<PolygonMeshEdge, i32> {
    let mut uses: BTreeMap<PolygonMeshEdge, i32> = BTreeMap::new();
    for face in &mesh.faces {
        for i in 0..face.vertices.len() {
            *uses
                .entry(PolygonMeshEdge::new(
                    face.vertices[i],
                    face.vertices[(i + 1) % face.vertices.len()],
                ))
                .or_insert(0) += 1;
        }
    }
    uses
}

fn identity() -> Float4x4 {
    Float4x4::new_with_columns(
        Float4::new(1.0, 0.0, 0.0, 0.0),
        Float4::new(0.0, 1.0, 0.0, 0.0),
        Float4::new(0.0, 0.0, 1.0, 0.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    )
}

fn materials(count: usize) -> Vec<MeshMaterial> {
    vec![MeshMaterial::fallback(); count]
}

// Face subdivision preserves shape, shared edges and independent corner UV seams.
#[test]
fn subdivide_faces() {
    let mut mesh = GeometryPrimitives::unit_box().unwrap();
    let source = mesh.clone();
    let selected = mesh
        .subdivide_faces(&set(&[1]), GeometryLimits::default())
        .unwrap();
    assert_eq!(selected.len(), 4);
    assert_eq!((mesh.faces.len(), mesh.positions.len()), (9, 13));
    assert_eq!(&mesh.positions[..8], &source.positions[..]);
    assert_eq!(
        mesh.faces
            .iter()
            .filter(|face| face.vertices.len() == 5)
            .count(),
        4
    );
    for index in &selected {
        let face = &mesh.faces[*index as usize];
        assert_eq!(face.vertices.len(), 4);
        assert_eq!(face.uvs.as_ref().unwrap().len(), 4);
    }
    // Every inserted midpoint participates in both neighboring surfaces.
    assert!(edge_uses(&mesh).values().all(|count| *count == 2));
    mesh.bake_default("subdivided").unwrap();

    let mut full = source.clone();
    let all: BTreeSet<i64> = (0..full.faces.len() as i64).collect();
    full.subdivide_faces(&all, GeometryLimits::default())
        .unwrap();
    assert_eq!((full.positions.len(), full.faces.len()), (26, 24));
    assert!(
        full.positions
            .iter()
            .all(|p| p.x.abs().max(p.y.abs()).max(p.z.abs()) == 0.5)
    );

    let before = full.clone();
    assert!(
        full.subdivide_faces(&set(&[-1]), GeometryLimits::default())
            .is_err()
    );
    assert_eq!(
        full.subdivide_faces(&set(&[0]), GeometryLimits::new(26, 1_000_000))
            .unwrap_err(),
        GeometryError::BudgetExceeded
    );
    assert_eq!(full, before);

    let mut concave = PolygonMesh::new(
        vec![
            Float3::new(0.0, 0.0, 0.0),
            Float3::new(3.0, 0.0, 0.0),
            Float3::new(3.0, 3.0, 0.0),
            Float3::new(2.0, 3.0, 0.0),
            Float3::new(2.0, 1.0, 0.0),
            Float3::new(1.0, 1.0, 0.0),
            Float3::new(1.0, 3.0, 0.0),
            Float3::new(0.0, 3.0, 0.0),
        ],
        vec![diffuse_assets::geometry::polygon_mesh::PolygonFace::with_vertices((0..8).collect())],
    );
    let concave_source = concave.clone();
    assert!(
        concave
            .subdivide_faces(&set(&[0]), GeometryLimits::default())
            .is_err()
    );
    assert_eq!(concave, concave_source);
    let triangles = concave
        .triangulate_faces(&set(&[0]), GeometryLimits::default())
        .unwrap();
    concave
        .subdivide_faces(&triangles, GeometryLimits::default())
        .unwrap();
    concave
        .bake_default("concave subdivided after triangulation")
        .unwrap();
}

// Explicit triangulation preserves the rendered surface and corner attributes.
#[test]
fn triangulate_faces() {
    let mut mesh = GeometryPrimitives::unit_box().unwrap();
    let source = mesh.clone();
    let before = mesh
        .bake(
            "before",
            GeometryShading::Flat,
            &materials(1),
            GeometryLimits::default(),
        )
        .unwrap();
    let selected = mesh
        .triangulate_faces(&set(&[0, 1]), GeometryLimits::default())
        .unwrap();
    assert_eq!((mesh.faces.len(), selected.len()), (8, 4));
    assert_eq!(mesh.positions, source.positions);
    for index in &selected {
        let face = &mesh.faces[*index as usize];
        assert_eq!(face.vertices.len(), 3);
        assert_eq!(face.uvs.as_ref().unwrap().len(), 3);
    }
    let after = mesh
        .bake(
            "after",
            GeometryShading::Flat,
            &materials(1),
            GeometryLimits::default(),
        )
        .unwrap();
    assert_eq!(after.mesh.triangle_count(), before.mesh.triangle_count());
    let triangulated = mesh.clone();
    assert_eq!(
        mesh.triangulate_faces(&set(&[2]), GeometryLimits::new(250_000, 1))
            .unwrap_err(),
        GeometryError::BudgetExceeded
    );
    assert_eq!(mesh, triangulated);
}

// Adjacent faces extrude as a region without an internal wall.
#[test]
fn adjacent_region() {
    let source =
        GeometryPrimitives::grid(Float2::new(2.0, 1.0), (2, 1), GeometryLimits::default()).unwrap();
    let mut mesh = source.clone();
    mesh.extrude_faces(
        &set(&[0, 1]),
        Float3::new(0.0, 1.0, 0.0),
        GeometryLimits::default(),
    )
    .unwrap();
    assert_eq!(mesh.positions.len(), 12);
    // Two caps plus six boundary walls.
    assert_eq!(mesh.faces.len(), 8);
    assert_eq!(mesh.faces[0].uvs, source.faces[0].uvs);
    assert_eq!(mesh.faces[1].uvs, source.faces[1].uvs);
    assert!(mesh.positions.iter().all(|p| p.y == 0.0 || p.y == 1.0));
    mesh.bake_default("region").unwrap();
    assert_eq!((source.positions.len(), source.faces.len()), (6, 2));
}

// Extrusion removes unused interior base vertices and preserves closed topology.
#[test]
fn topology() {
    let mut grid =
        GeometryPrimitives::grid(Float2::new(2.0, 2.0), (4, 4), GeometryLimits::default()).unwrap();
    let all: BTreeSet<i64> = (0..grid.faces.len() as i64).collect();
    grid.extrude_faces(&all, Float3::new(0.0, 1.0, 0.0), GeometryLimits::default())
        .unwrap();
    // Sixteen boundary bases plus twenty-five cap vertices.
    assert_eq!(grid.positions.len(), 41);
    assert_eq!(grid.faces.len(), 32);
    let referenced: BTreeSet<i64> = grid
        .faces
        .iter()
        .flat_map(|face| face.vertices.clone())
        .collect();
    assert_eq!(referenced.len(), grid.positions.len());

    let mut mesh = GeometryPrimitives::unit_box().unwrap();
    mesh.extrude_faces(
        &set(&[1, 3]),
        Float3::new(0.0, 0.5, 0.5),
        GeometryLimits::default(),
    )
    .unwrap();
    assert_eq!(mesh.faces.len(), 12);
    assert!(edge_uses(&mesh).values().all(|count| *count == 2));
    mesh.bake_default("closed").unwrap();
}

// Bad selections and geometric degeneracy fail without changing the mesh.
#[test]
fn transactional_failures() {
    let mut grid =
        GeometryPrimitives::grid(Float2::new(2.0, 2.0), (2, 2), GeometryLimits::default()).unwrap();
    let original = grid.clone();
    assert!(
        grid.extrude_faces(
            &set(&[0, 3]),
            Float3::new(0.0, 1.0, 0.0),
            GeometryLimits::default()
        )
        .is_err()
    );
    assert_eq!(grid, original);
    assert!(
        grid.extrude_faces(
            &set(&[99]),
            Float3::new(0.0, 1.0, 0.0),
            GeometryLimits::default()
        )
        .is_err()
    );
    assert_eq!(
        grid.extrude_faces(
            &set(&[0]),
            Float3::new(0.0, 1.0, 0.0),
            GeometryLimits::new(9, 1_000_000)
        )
        .unwrap_err(),
        GeometryError::BudgetExceeded
    );
    assert_eq!(grid, original);

    let mut invalid = identity();
    invalid.columns[0].x = f32::NAN;
    assert!(
        grid.transform(&set(&[0]), invalid, GeometryLimits::default())
            .is_err()
    );
    assert_eq!(grid, original);

    let mut collapse = identity();
    collapse.columns[0].x = 0.0;
    let every: BTreeSet<i64> = (0..grid.positions.len() as i64).collect();
    assert!(
        grid.transform(&every, collapse, GeometryLimits::default())
            .is_err()
    );
    assert_eq!(grid, original);
}

// Affine vertex transformations preserve unselected vertices and corner attributes.
#[test]
fn affine_transform() {
    let mut mesh = GeometryPrimitives::unit_box().unwrap();
    let before = mesh.clone();
    let mut transform = identity();
    transform.columns[3].x = 0.1;
    mesh.transform(&set(&[0, 1]), transform, GeometryLimits::default())
        .unwrap();
    assert_eq!(
        mesh.positions[0],
        before.positions[0] + Float3::new(0.1, 0.0, 0.0)
    );
    assert_eq!(
        mesh.positions[1],
        before.positions[1] + Float3::new(0.1, 0.0, 0.0)
    );
    assert_eq!(mesh.positions[2], before.positions[2]);
    assert_eq!(mesh.faces, before.faces);
    assert_eq!(mesh.edges(), before.edges());
}

// Preview overlays preserve the authored catalog and survive reload until removed.
#[test]
fn preview_overlay() {
    let root = std::env::temp_dir().join(format!("mesh-preview-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let path = root.join("asset.dmesh");
    let mut document =
        GeometryDocument::with_source("authored", GeometrySource::Box { size: Float3::ONE });
    document
        .save(&path.to_string_lossy(), GeometryLimits::default())
        .unwrap();

    let registry = AssetRegistry::new();
    let entry = registry
        .load_project_default(&root.to_string_lossy())
        .unwrap()
        .into_iter()
        .next()
        .unwrap();
    let preview = GeometryDocument::with_source(
        "preview",
        GeometrySource::Box {
            size: Float3::splat(3.0),
        },
    )
    .evaluate(GeometryLimits::default())
    .unwrap();
    registry.register_transient_mesh(
        preview.mesh.clone(),
        entry.mesh_index,
        &entry.id,
        entry.kind,
        Some(vec![preview.topology_slice.clone()]),
        None,
    );
    assert_eq!(
        registry
            .mesh_asset(entry.mesh_index)
            .unwrap()
            .local_bounds()
            .1
            .x,
        1.5
    );

    document.source = GeometrySource::Box {
        size: Float3::splat(2.0),
    };
    document
        .save(&path.to_string_lossy(), GeometryLimits::default())
        .unwrap();
    let _ = registry
        .load_project_default(&root.to_string_lossy())
        .unwrap();
    assert_eq!(
        registry.mesh_asset(entry.mesh_index).unwrap().name,
        "preview"
    );

    registry.unregister_transient_mesh(entry.mesh_index);
    let restored = registry.mesh_asset(entry.mesh_index).unwrap();
    // 2×2×2 box normalized to unit bounds then scaled back to a 2-unit extent.
    assert_eq!(restored.local_bounds().1.x, 1.0);
    assert_eq!(
        GeometryDocument::load(&path.to_string_lossy()).unwrap(),
        document
    );
    let _ = std::fs::remove_dir_all(&root);
    let _ = capability(GeometryLimits::default());
}

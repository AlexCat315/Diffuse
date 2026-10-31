//! Ported from `Engine/Tests/AssetPipelineTests/MeshAssetTests.swift`.

use diffuse_assets::asset_pipeline::{BuiltinMesh, MeshAsset, OBJLoader};
use diffuse_math::simd::simd_compat::{Float2, Float3, Float4, Float4x4};

// Mesh exposes vertex and triangle counts.
#[test]
fn mesh_exposes_counts() {
    let mut vertices: Vec<f32> = Vec::new();
    MeshAsset::append_default_vertex(&mut vertices, Float3::new(0.0, 0.0, 0.0));
    MeshAsset::append_default_vertex(&mut vertices, Float3::new(1.0, 0.0, 0.0));
    MeshAsset::append_default_vertex(&mut vertices, Float3::new(0.0, 1.0, 0.0));
    let mesh = MeshAsset::new("tri", vertices, vec![0, 1, 2]);
    assert_eq!(mesh.vertex_count(), 3);
    assert_eq!(mesh.triangle_count(), 1);
}

// Mesh exposes position accessors.
#[test]
fn mesh_exposes_position_accessors() {
    let mut vertices: Vec<f32> = Vec::new();
    MeshAsset::append_default_vertex(&mut vertices, Float3::new(0.0, 0.0, 0.0));
    MeshAsset::append_default_vertex(&mut vertices, Float3::new(1.0, 0.0, 0.0));
    let mut mesh = MeshAsset::new("line", vertices, vec![0, 1]);
    assert_eq!(mesh.position(1), Some(Float3::new(1.0, 0.0, 0.0)));
    mesh.set_position(Float3::new(2.0, 3.0, 4.0), 1);
    assert_eq!(mesh.position(1), Some(Float3::new(2.0, 3.0, 4.0)));
    assert_eq!(mesh.position(5), None);
}

// Mesh transforms positions.
#[test]
fn mesh_transforms_positions() {
    let mut vertices: Vec<f32> = Vec::new();
    MeshAsset::append_default_vertex(&mut vertices, Float3::new(1.0, 2.0, 3.0));
    let mut mesh = MeshAsset::new("point", vertices, vec![0]);
    let matrix = Float4x4::from_rows(&[
        Float4::new(1.0, 0.0, 0.0, 4.0),
        Float4::new(0.0, 1.0, 0.0, 5.0),
        Float4::new(0.0, 0.0, 1.0, 6.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ]);
    mesh.transform_positions(matrix);
    assert_eq!(mesh.position(0), Some(Float3::new(5.0, 7.0, 9.0)));
}

// The built-in cube keeps its 24-vertex, 36-index, per-face-colored layout.
#[test]
fn builtin_cube_layout() {
    let cube = BuiltinMesh::default_cube();
    assert_eq!(cube.name, "builtin.cube");
    assert_eq!(cube.vertex_count(), 24);
    assert_eq!(cube.index_count(), 36);
    assert_eq!(cube.triangle_count(), 12);
    assert_eq!(cube.local_bounds().0, Float3::new(-0.5, -0.5, -0.5));
    assert_eq!(cube.local_bounds().1, Float3::new(0.5, 0.5, 0.5));
    // Swift's default argument for `color` leaves the per-face colors in place.
    let first_color = (
        cube.vertices[MeshAsset::COLOR_FLOAT_OFFSET],
        cube.vertices[MeshAsset::COLOR_FLOAT_OFFSET + 1],
        cube.vertices[MeshAsset::COLOR_FLOAT_OFFSET + 2],
    );
    assert_eq!(first_color, (1.0, 0.2, 0.2));
    let tinted = BuiltinMesh::cube(Some(Float3::new(0.1, 0.2, 0.3)));
    assert_eq!(tinted.vertices[MeshAsset::COLOR_FLOAT_OFFSET], 0.1);
}

// An empty material list falls back to the single default material.
#[test]
fn empty_materials_fall_back() {
    let mesh = MeshAsset::with_materials("m", Vec::new(), Vec::new(), Vec::new());
    assert_eq!(
        mesh.materials,
        vec![diffuse_assets::asset_pipeline::MeshMaterial::fallback()]
    );
}

// Normalizing recenters and rescales to the requested extent.
#[test]
fn normalize_to_unit_bounds() {
    let mut vertices: Vec<f32> = Vec::new();
    MeshAsset::append_default_vertex(&mut vertices, Float3::new(0.0, 0.0, 0.0));
    MeshAsset::append_default_vertex(&mut vertices, Float3::new(4.0, 0.0, 0.0));
    let mut mesh = MeshAsset::new("span", vertices, vec![0, 1]);
    mesh.normalize_to_unit_bounds(2.0);
    assert_eq!(mesh.local_bounds().0, Float3::new(-1.0, 0.0, 0.0));
    assert_eq!(mesh.local_bounds().1, Float3::new(1.0, 0.0, 0.0));
}

// The minimal OBJ loader triangulates fan-style and fills missing normals.
#[test]
fn obj_loader_parses_and_fills_normals() {
    let text = "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n";
    let mesh = OBJLoader::parse(text, "tri.obj").unwrap();
    assert_eq!(mesh.name, "tri.obj");
    assert_eq!(mesh.vertex_count(), 3);
    assert_eq!(mesh.triangle_count(), 1);
    // Swift normalizes a face normal of (0,0,1) into every zeroed slot.
    assert_eq!(mesh.vertices[MeshAsset::NORMAL_FLOAT_OFFSET], 0.0);
    assert_eq!(mesh.vertices[MeshAsset::NORMAL_FLOAT_OFFSET + 2], 1.0);
}

// Supplied `vn` normals are left untouched.
#[test]
fn obj_loader_keeps_supplied_normals() {
    let text = "v 0 0 0\nv 1 0 0\nv 0 1 0\nvn 0 1 0\nf 1//1 2//1 3//1\n";
    let mesh = OBJLoader::parse(text, "kept.obj").unwrap();
    assert_eq!(mesh.vertices[MeshAsset::NORMAL_FLOAT_OFFSET + 1], 1.0);
}

// OBJ parse failures match Swift's messages.
#[test]
fn obj_loader_rejects_malformed_input() {
    let error = OBJLoader::parse("v 0 0\n", "bad.obj").unwrap_err();
    assert_eq!(
        error,
        diffuse_assets::asset_pipeline::OBJLoaderError::ParseFailed(
            "bad vertex: v 0 0".to_string()
        )
    );
    let empty = OBJLoader::parse("v 0 0 0\n", "empty.obj").unwrap_err();
    assert_eq!(
        empty,
        diffuse_assets::asset_pipeline::OBJLoaderError::ParseFailed(
            "no triangles parsed".to_string()
        )
    );
    let out_of_range =
        OBJLoader::parse("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 9\n", "range.obj").unwrap_err();
    assert_eq!(
        out_of_range,
        diffuse_assets::asset_pipeline::OBJLoaderError::ParseFailed(
            "face position out of range: 9".to_string()
        )
    );
}

// `append_vertex` writes the documented 24-float layout in order.
#[test]
fn append_vertex_layout() {
    let mut vertices: Vec<f32> = Vec::new();
    MeshAsset::append_vertex(
        &mut vertices,
        Float3::new(1.0, 2.0, 3.0),
        Float3::new(4.0, 5.0, 6.0),
        Float3::new(7.0, 8.0, 9.0),
        Float2::new(10.0, 11.0),
        Float4::new(12.0, 13.0, 14.0, 15.0),
        16.0,
        Float4::new(17.0, 18.0, 19.0, 20.0),
        Float4::new(21.0, 22.0, 23.0, 24.0),
    );
    assert_eq!(
        vertices,
        (1..=24).map(|value| value as f32).collect::<Vec<_>>()
    );
    assert_eq!(MeshAsset::VERTEX_STRIDE, 96);
    assert_eq!(MeshAsset::POSITION_OFFSET, 0);
    assert_eq!(MeshAsset::WEIGHTS_OFFSET, 80);
}

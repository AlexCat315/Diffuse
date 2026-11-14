//! `Editor/Tests/EditorCoreTests/MeshPickerTests.swift`.

use std::collections::BTreeSet;

use cove_ui_compose::scene_core::Rect;
use diffuse_assets::geometry::geometry_primitives::GeometryPrimitives;
use diffuse_assets::geometry::polygon_mesh::{PolygonFace, PolygonMesh, PolygonMeshEdge};
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4};
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderCameraProjection};

use crate::editing::viewport::editor_viewport_projection::EditorViewportProjection;
use crate::geometry::editor_mesh_picker::{EditorMeshPicker, EditorMeshSelectionMode};
use crate::rendering::viewport::viewport_host::ViewportScreenFrame;

fn projection(
    kind: RenderCameraProjection,
    target: Float3,
    x: f32,
    y: f32,
) -> EditorViewportProjection {
    let camera = RenderCamera {
        projection: kind,
        orthographic_height: 4.0,
        ..RenderCamera::new(target + Float3::new(0.0, 0.0, 5.0), target)
    };
    EditorViewportProjection::new(camera, ViewportScreenFrame::new(x, y, 800.0, 600.0))
        .expect("viewport projection")
}

fn box_picker(world: Float4x4) -> EditorMeshPicker<'static> {
    EditorMeshPicker::new(GeometryPrimitives::unit_box().expect("box"), world, None)
        .expect("mesh picker")
}

#[test]
fn vertices_and_edges_reject_occluded_cage_elements() {
    let mesh = box_picker(MATRIX_IDENTITY_FLOAT4X4);
    for kind in [
        RenderCameraProjection::Perspective,
        RenderCameraProjection::Orthographic,
    ] {
        let projection = projection(kind, Float3::ZERO, 70.0, 90.0);
        assert!(
            !mesh.is_visible(mesh.positions[0], &projection, false),
            "{kind:?}"
        );
        assert!(
            mesh.is_visible(mesh.positions[0], &projection, true),
            "{kind:?}"
        );
        assert!(
            mesh.is_visible(mesh.positions[4], &projection, false),
            "{kind:?}"
        );
        let (x, y) = projection
            .project_default(mesh.positions[4])
            .expect("vertex projection");
        assert_eq!(
            mesh.pick(
                x,
                y,
                EditorMeshSelectionMode::Vertex,
                &projection,
                false,
                8.0
            )
            .map(|hit| hit.index),
            Some(4),
            "{kind:?}"
        );
        let edge = mesh
            .edges
            .iter()
            .position(|edge| *edge == PolygonMeshEdge::new(6, 7))
            .expect("edge");
        let (x, y) = projection
            .project_default((mesh.positions[6] + mesh.positions[7]) * 0.5)
            .expect("edge projection");
        assert_eq!(
            mesh.pick(x, y, EditorMeshSelectionMode::Edge, &projection, false, 8.0)
                .map(|hit| hit.index),
            Some(edge),
            "{kind:?}"
        );
        assert_eq!(
            mesh.pick(
                0.0,
                0.0,
                EditorMeshSelectionMode::Vertex,
                &projection,
                false,
                8.0
            ),
            None,
            "{kind:?}"
        );
    }
}

#[test]
fn orthographic_marquee_supports_through_selection_and_keeps_point_priority() {
    let mesh = box_picker(MATRIX_IDENTITY_FLOAT4X4);
    let projection = projection(RenderCameraProjection::Orthographic, Float3::ZERO, 0.0, 0.0);
    let (x, y) = projection
        .project_default(mesh.positions[4])
        .expect("vertex projection");
    let rect = Rect::new(x - 2.0, y - 2.0, 4.0, 4.0);
    assert_eq!(
        mesh.pick_in_rect(rect, EditorMeshSelectionMode::Vertex, &projection, false),
        BTreeSet::from([4]),
    );
    assert_eq!(
        mesh.pick_in_rect(rect, EditorMeshSelectionMode::Vertex, &projection, true),
        BTreeSet::from([0, 4]),
    );
    assert_eq!(
        mesh.pick(
            x,
            y,
            EditorMeshSelectionMode::Vertex,
            &projection,
            true,
            8.0
        )
        .map(|hit| hit.index),
        Some(4),
    );
}

#[test]
fn face_hits_use_concave_triangles_and_world_distances_under_negative_scale() {
    let target = Float3::new(1.0, -1.0, 0.0);
    let transform = Float4x4::from_columns([
        Float4::new(-2.0, 0.0, 0.0, 0.0),
        Float4::new(0.0, 1.5, 0.0, 0.0),
        Float4::new(0.0, 0.0, 0.5, 0.0),
        Float4::new(1.0, -1.0, 0.0, 1.0),
    ]);
    let mesh = box_picker(transform);
    let view = projection(RenderCameraProjection::Orthographic, target, 0.0, 0.0);
    let (x, y) = view.project_default(target).expect("projection center");
    let hit = mesh
        .pick(x, y, EditorMeshSelectionMode::Face, &view, false, 8.0)
        .expect("face hit");
    assert_eq!(hit.index, 1);
    assert!((hit.distance - (5.0 - view.camera.near - 0.25)).abs() < 1e-5);

    let concave = PolygonMesh::new(
        [
            (0.0, 0.0),
            (2.0, 0.0),
            (2.0, 1.0),
            (1.0, 1.0),
            (1.0, 2.0),
            (0.0, 2.0),
        ]
        .map(|(x, y)| Float3::new(x, y, 0.0))
        .to_vec(),
        vec![PolygonFace::with_vertices(vec![0, 1, 2, 3, 4, 5])],
    );
    let mesh =
        EditorMeshPicker::new(concave, MATRIX_IDENTITY_FLOAT4X4, None).expect("concave picker");
    let view = projection(
        RenderCameraProjection::Orthographic,
        Float3::new(1.0, 1.0, 0.0),
        0.0,
        0.0,
    );
    for (point, expected) in [(1.5, None), (0.5, Some(0))] {
        let (x, y) = view
            .project_default(Float3::new(point, point, 0.0))
            .expect("face projection");
        assert_eq!(
            mesh.pick(x, y, EditorMeshSelectionMode::Face, &view, false, 8.0)
                .map(|hit| hit.index),
            expected,
        );
    }
}

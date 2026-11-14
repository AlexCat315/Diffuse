//! `Editor/Tests/EditorCoreTests/MeshRenderingTests.swift`.

use diffuse_assets::geometry::geometry_document::GeometrySource;
use diffuse_assets::geometry::geometry_modifier::GeometryModifier;
use diffuse_assets::geometry::polygon_mesh::{PolygonFace, PolygonMesh};
use diffuse_math::simd::simd_compat::{
    Float2, Float3, Float4, MATRIX_IDENTITY_FLOAT4X4, simd_cross, simd_length,
};
use diffuse_render::RenderDrawableSize;
use diffuse_scene::rendering::render_geometry_overlay::{
    RenderGeometryLine, RenderGeometryOverlay,
};
use diffuse_scene::rendering::render_scene::RenderCamera;

use super::mesh_editing_tests::MeshProject;
use crate::editing::viewport::editor_viewport_render_gate::{
    EditorViewportRenderGate, EditorViewportRenderGateSignature,
};
use crate::geometry::editor_mesh_picker::EditorMeshSelectionMode as Mode;
use crate::state::editor_reducer::EditorAction;
use crate::state::workspace::editor_workbench_state::EditorViewportMode;

const VIEWPORT: Float2 = Float2::new(800.0, 600.0);

fn selected_edges(overlay: &RenderGeometryOverlay) -> usize {
    overlay
        .triangles
        .iter()
        .flat_map(|triangle| {
            let widths = triangle.edge_widths;
            [widths.x, widths.y, widths.z]
        })
        .filter(|&width| width == 2.0)
        .count()
}

#[test]
fn mesh_overlay_updates_on_selection_mode_and_xray_changes() {
    let project = MeshProject::new();
    let model = &project.editing;
    assert!(model.set_mode(Mode::Face));
    project.select([1]);
    let overlay = model.geometry_overlays(VIEWPORT).pop().expect("overlay");
    let filled: Vec<_> = overlay
        .triangles
        .iter()
        .filter(|triangle| triangle.color.w > 0.0)
        .collect();
    assert_eq!(filled.len(), 2);
    assert_eq!(overlay.triangles.len(), 12);
    assert_eq!(selected_edges(&overlay), 8);
    assert!(
        filled
            .iter()
            .all(|t| t.a.z == 0.5 && t.b.z == 0.5 && t.c.z == 0.5 && t.color.w < 1.0)
    );
    project.select([]);
    assert!(
        model
            .geometry_overlays(VIEWPORT)
            .last()
            .expect("overlay")
            .triangles
            .iter()
            .all(|t| t.color.w == 0.0)
    );
    project.select([1]);
    model.set_xray(true);
    assert!(
        model
            .geometry_overlays(VIEWPORT)
            .last()
            .expect("overlay")
            .xray
    );
    assert!(model.set_mode(Mode::Edge));
    project.select([0]);
    let overlay = model
        .geometry_overlays(VIEWPORT)
        .pop()
        .expect("edge overlay");
    assert!(overlay.triangles.iter().all(|t| t.color.w == 0.0) && overlay.points.is_empty());
    assert_eq!(selected_edges(&overlay), 2);
    project
        .store
        .dispatch(EditorAction::SetViewportMode(EditorViewportMode::Game));
    assert!(model.geometry_overlays(VIEWPORT).is_empty());
}

#[test]
fn overlay_follows_concavity_negative_world_scale_and_transient_topology() {
    let project = MeshProject::new();
    let model = &project.editing;
    let polygon = PolygonMesh::new(
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
    assert!(project.authoring.edit(project.id, |doc| {
        doc.source = GeometrySource::Polygon { mesh: polygon };
        Ok(())
    }));
    let mut world = MATRIX_IDENTITY_FLOAT4X4;
    world.set_column(0, Float4::new(-2.0, 0.0, 0.0, 0.0));
    world.set_column(3, Float4::new(3.0, 0.0, 0.0, 1.0));
    project.scene.set_entity_local_matrix(project.id, world);
    assert!(model.set_mode(Mode::Face));
    project.select([0]);
    let overlay = model
        .geometry_overlays(VIEWPORT)
        .pop()
        .expect("concave overlay");
    let area: f32 = overlay
        .triangles
        .iter()
        .map(|t| simd_length(simd_cross(t.b - t.a, t.c - t.a)) * 0.5)
        .sum();
    assert_eq!(overlay.triangles.len(), 4);
    assert!((area - 6.0).abs() < 1e-5);
    assert!(
        overlay
            .triangles
            .iter()
            .all(|t| t.a.x <= 3.0 && t.b.x <= 3.0 && t.c.x <= 3.0)
    );
    model.leave();
    assert!(project.authoring.edit(project.id, |doc| {
        doc.source = GeometrySource::Box { size: Float3::ONE };
        Ok(())
    }));
    assert!(model.set_mode(Mode::Face));
    project.select([1]);
    assert!(model.begin_inset());
    let inset = model
        .geometry_overlays(VIEWPORT)
        .pop()
        .expect("inset overlay");
    assert_eq!(inset.triangles.len(), 20);
    assert_eq!(
        inset.triangles.iter().filter(|t| t.color.w > 0.0).count(),
        2
    );
    assert!(model.cancel_inset());
    assert_eq!(
        model
            .geometry_overlays(VIEWPORT)
            .last()
            .expect("restored overlay")
            .triangles
            .len(),
        12
    );
}

#[test]
fn evaluated_wireframe_and_object_outlines_use_depth_tested_geometry() {
    let project = MeshProject::new();
    let model = &project.editing;
    assert!(
        project
            .authoring
            .add_modifier(GeometryModifier::Subdivision { levels: 1 }, project.id)
    );
    assert!(model.set_mode(Mode::Face));
    project.select([1]);
    let overlays = model.geometry_overlays(VIEWPORT);
    assert_eq!(overlays.len(), 2);
    assert_eq!(overlays[0].triangles.len(), 48);
    assert_eq!(overlays[1].triangles.len(), 12);
    assert!(overlays.iter().all(|overlay| !overlay.xray));
    model.leave();
    project.scene.tick_scene_default();
    let object = model.geometry_overlays(VIEWPORT);
    assert_eq!(object.len(), 1);
    assert!(!object[0].triangles.is_empty());
    assert!(object[0].triangles.iter().all(|t| t.color.w == 0.0));
}

#[test]
fn overlay_changes_invalidate_the_idle_render_gate() {
    let mut gate = EditorViewportRenderGate::new();
    let mut signature = EditorViewportRenderGateSignature::new(
        1,
        RenderCamera::new(Float3::new(0.0, 0.0, 5.0), Float3::ZERO),
        RenderDrawableSize::new(800, 600),
        1,
        Default::default(),
    );
    let mut submit = |signature: &EditorViewportRenderGateSignature, time| {
        gate.should_render_default(signature.clone(), false, false, false, time)
    };
    assert!(submit(&signature, 0.0));
    assert!(submit(&signature, 0.01));
    assert!(!submit(&signature, 0.02));
    let mut overlay = RenderGeometryOverlay::new(VIEWPORT);
    overlay.lines.push(RenderGeometryLine::new(
        Float3::ZERO,
        Float3::new(1.0, 0.0, 0.0),
        Float4::new(1.0, 0.5, 0.0, 1.0),
    ));
    signature.geometry_overlays = vec![overlay];
    assert!(submit(&signature, 0.03));
    assert!(submit(&signature, 0.04));
    assert!(!submit(&signature, 0.05));
    signature.geometry_overlays.clear();
    assert!(submit(&signature, 0.06));
}

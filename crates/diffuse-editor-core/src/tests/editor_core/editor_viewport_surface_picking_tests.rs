//! Ported from `Editor/Tests/EditorCoreTests/EditorViewportSurfacePickingTests.swift`.

use diffuse_scene::components::core::registry::ComponentRegistry;

use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

fn make_adapter() -> EditorSceneAdapter {
    EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    )
}

/// Material coverage and authored LOD survive scene save and load, including
/// missing optional fields.
#[test]
fn scene_persistence() {
    use diffuse_math::simd::simd_compat::{Float3, Float4};
    use diffuse_scene::rendering::render_extraction::{
        RenderMaterialComponent, RenderMeshComponent,
    };
    use diffuse_scene::rendering::render_scene::MaterialAlphaMode;
    use diffuse_scene::rendering::render_scene::RenderMeshLOD;
    use diffuse_scene::scene_runtime::SceneRuntime;

    use crate::scene::manifest::node::EditorSceneManifestNode;

    let adapter = make_adapter();
    let id = adapter
        .spawn_entity_default(crate::scene::adapter::spawn::EditorEntityTemplate::Cube)
        .expect("cube");
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(id);
    let material = RenderMaterialComponent::new(
        Float4::new(1.0, 1.0, 1.0, 0.4),
        None,
        None,
        0.0,
        0.5,
        Float3::ZERO,
        Some(MaterialAlphaMode::Blend),
        Some(0.35),
        Some(true),
    );
    adapter.with_scene_mut(|scene| {
        scene.set_component(material.clone(), entity);
        if let Some(mut mesh) = scene.component::<RenderMeshComponent>(entity) {
            mesh.levels_of_detail = vec![RenderMeshLOD::new(3, 20.0)];
            scene.set_component(mesh, entity);
        }
    });

    let data = serde_json::to_vec(&adapter.manifest()).expect("encode manifest");
    let saved: crate::scene::manifest::editor_scene_manifest::EditorSceneManifest =
        serde_json::from_slice(&data).expect("decode manifest");
    let restored = make_adapter();
    restored.set_scene(SceneRuntime::new(ComponentRegistry::built_in()));
    let _ = restored.load(&saved);
    let scene = restored.scene();
    assert_eq!(
        scene.component::<RenderMaterialComponent>(entity),
        Some(material)
    );
    assert_eq!(
        scene
            .component::<RenderMeshComponent>(entity)
            .map(|mesh| mesh.levels_of_detail),
        Some(vec![RenderMeshLOD::new(3, 20.0)])
    );

    let empty: EditorSceneManifestNode =
        serde_json::from_str(r#"{"id":0,"name":"Empty","kind":"empty"}"#).expect("empty node");
    assert!(empty.components.is_empty());
    assert!(empty.children.is_empty());
}

/// A triangle's blank bounding-box corner stays unselected despite its collider.
#[test]
fn triangle_and_collider() {
    use diffuse_assets::asset_pipeline::MeshAsset;
    use diffuse_assets::asset_registry::ImportableAssetKind;
    use diffuse_math::simd::simd_compat::{Float2, Float3, Float4};
    use diffuse_render::registries::mesh_bounds_registry::MeshBoundsRegistry;
    use diffuse_render::registries::mesh_picking_registry::MeshPickingRegistry;
    use diffuse_scene::rendering::render_scene::RenderCameraProjection;

    use crate::assets::asset_catalog::EditorAsset;
    use crate::editing::viewport::editor_viewport_projection::EditorViewportProjection;
    use crate::rendering::viewport::viewport_host::ViewportScreenFrame;

    let slot = 402_001;
    let mut vertices: Vec<f32> = Vec::new();
    for position in [
        Float3::new(-1.0, -1.0, 0.0),
        Float3::new(1.0, -1.0, 0.0),
        Float3::new(-1.0, 1.0, 0.0),
    ] {
        MeshAsset::append_vertex(
            &mut vertices,
            position,
            Float3::new(0.0, 0.0, 1.0),
            Float3::new(1.0, 1.0, 1.0),
            Float2::ZERO,
            Float4::new(0.0, 0.0, 0.0, 1.0),
            0.0,
            Float4::ZERO,
            Float4::ZERO,
        );
    }
    let mesh = MeshAsset::new("triangle", vertices, vec![0, 1, 2]);
    MeshPickingRegistry::register(slot, &mesh);
    let (local_min, local_max) = mesh.local_bounds();
    MeshBoundsRegistry::register_min_max(slot, local_min, local_max);

    for (projection_kind, orthographic) in [
        (RenderCameraProjection::Perspective, false),
        (RenderCameraProjection::Orthographic, true),
    ] {
        let adapter = make_adapter();
        adapter.set_editor_viewport_camera_enabled(true);
        adapter.look_along_axis(Float3::new(0.0, 0.0, -1.0), orthographic);
        let asset = EditorAsset::new(
            "triangle",
            "triangle",
            "triangle.obj",
            "/tmp/triangle.obj",
            ImportableAssetKind::Obj,
            slot,
        );
        let raw_id = adapter
            .spawn_entity_from_asset_default(&asset)
            .expect("triangle spawn");
        adapter.tick_scene_default();
        let frame = ViewportScreenFrame::new(0.0, 0.0, 800.0, 600.0);
        let projection = EditorViewportProjection::new(adapter.current_render_camera(), frame)
            .expect("projection");
        let empty = projection
            .project_default(Float3::new(0.8, 0.8, 0.0))
            .expect("empty corner");
        assert_eq!(
            adapter.pick_entity(empty.0, empty.1, frame),
            None,
            "{projection_kind:?}"
        );
        let solid = projection
            .project_default(Float3::new(-0.6, -0.6, 0.0))
            .expect("solid area");
        assert_eq!(
            adapter.pick_entity(solid.0, solid.1, frame),
            Some(raw_id),
            "{projection_kind:?}"
        );
    }
    MeshBoundsRegistry::clear_all();
}

/// Rotated, negatively scaled meshes retain world-distance ordering.
#[test]
fn rotated_and_scaled() {
    use std::f32::consts::PI;

    use diffuse_math::simd::simd_compat::{Float3, Float4x4, Quatf};
    use diffuse_scene::runtime_world::LocalTransform;

    use crate::editing::viewport::editor_viewport_projection::EditorViewportProjection;
    use crate::rendering::viewport::viewport_host::ViewportScreenFrame;
    use crate::scene::adapter::spawn::EditorEntityTemplate;

    let adapter = make_adapter();
    adapter.set_editor_viewport_camera_enabled(true);
    adapter.look_along_axis(Float3::new(0.0, 0.0, -1.0), true);
    let front = adapter
        .spawn_entity_default(EditorEntityTemplate::Cube)
        .expect("front cube");
    let rear = adapter
        .spawn_entity_default(EditorEntityTemplate::Cube)
        .expect("rear cube");
    let entity = diffuse_scene::entity_id::EntityID::from_raw_value(front);
    let mut matrix =
        Float4x4::from_quatf(Quatf::from_angle_axis(PI / 4.0, Float3::new(0.0, 1.0, 0.0)));
    matrix.columns[0] = matrix.columns[0] * -0.5;
    matrix.columns[1] = matrix.columns[1] * 2.0;
    matrix.columns[2] = matrix.columns[2] * 0.5;
    adapter.with_scene_mut(|scene| {
        scene.set_local_transform(LocalTransform::new(matrix), entity);
    });
    adapter.set_entity_local_translation(rear, Float3::new(0.0, 0.0, -3.0));
    adapter.tick_scene_default();
    let frame = ViewportScreenFrame::new(0.0, 0.0, 800.0, 600.0);
    let center = EditorViewportProjection::new(adapter.current_render_camera(), frame)
        .expect("projection")
        .project_default(Float3::ZERO)
        .expect("center");
    assert_eq!(adapter.pick_entity(center.0, center.1, frame), Some(front));
}

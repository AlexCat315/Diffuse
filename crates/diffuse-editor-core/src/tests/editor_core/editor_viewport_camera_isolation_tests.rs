//! Ported from `Editor/Tests/EditorCoreTests/EditorViewportCameraIsolationTests.swift`.

/// Default view separates axes and reset changes only the editor camera.
#[test]
fn default_view_and_reset() {
    use diffuse_math::simd::simd_compat::{Float3, simd_length};
    use diffuse_scene::components::core::registry::ComponentRegistry;

    use crate::editing::viewport::editor_viewport_projection::EditorViewportProjection;
    use crate::rendering::viewport::viewport_host::ViewportScreenFrame;
    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    adapter.set_editor_viewport_camera_enabled(true);
    adapter.tick_scene_default();
    let original = adapter.current_render_camera();
    let frame = ViewportScreenFrame::new(0.0, 0.0, 800.0, 600.0);
    let projection = EditorViewportProjection::new(original, frame).expect("projection");
    let origin = projection.project_default(Float3::ZERO).expect("origin");
    let tips: Vec<(f32, f32)> = [
        Float3::new(1.0, 0.0, 0.0),
        Float3::new(0.0, 1.0, 0.0),
        Float3::new(0.0, 0.0, 1.0),
    ]
    .into_iter()
    .map(|point| {
        let projected = projection.project_default(point).expect("axis tip");
        (projected.0 - origin.0, projected.1 - origin.1)
    })
    .collect();
    for first in 0..tips.len() {
        for second in (first + 1)..tips.len() {
            let determinant = tips[first].0 * tips[second].1 - tips[first].1 * tips[second].0;
            assert!(
                determinant.abs()
                    / (simd_length(Float3::new(tips[first].0, tips[first].1, 0.0))
                        * simd_length(Float3::new(tips[second].0, tips[second].1, 0.0)))
                    > 0.2
            );
        }
    }

    let authored = adapter.manifest();
    adapter.look_along_axis(Float3::new(0.0, 0.0, -1.0), true);
    adapter.pan_camera(60.0, 30.0, frame);
    adapter.reset_viewport_view();
    assert_eq!(adapter.current_render_camera(), original);
    let after = adapter.manifest();
    assert_eq!(after.roots, authored.roots);
    assert_eq!(after.revision, authored.revision);
    assert!(!adapter.can_undo_edit());
}

/// Navigation preserves authored camera, saved scene, and undo history.
#[test]
fn navigation_preserves_scene() {
    use std::collections::BTreeSet;

    use diffuse_kernel::input_event::KeyModifiers;
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::rendering::render_scene::RenderCameraProjection;

    use crate::rendering::viewport::viewport_host::ViewportScreenFrame;
    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    adapter.set_editor_viewport_camera_enabled(true);
    adapter.tick_scene_default();
    let before = adapter.manifest();
    let camera_before = adapter.current_render_camera();
    let frame = ViewportScreenFrame::new(0.0, 0.0, 800.0, 600.0);
    adapter.set_viewport_projection(RenderCameraProjection::Orthographic);
    adapter.orbit_camera(30.0, 10.0, frame);
    adapter.pan_camera(20.0, 10.0, frame);
    adapter.dolly_camera(15.0);
    adapter.zoom_camera(0.8);
    adapter.freelook_camera(5.0, 5.0, &BTreeSet::from([26]), KeyModifiers(0), 1.0 / 60.0);
    adapter.look_along_axis(Float3::new(1.0, 0.0, 0.0), false);
    let roots: BTreeSet<u64> = adapter.roots().into_iter().map(|node| node.id).collect();
    adapter.frame_entities(&roots, None);
    assert_ne!(adapter.current_render_camera(), camera_before);
    assert_eq!(
        adapter.current_render_scene().camera,
        adapter.current_render_camera()
    );
    assert_eq!(adapter.manifest(), before);
    assert!(!adapter.can_undo_edit());
    assert!(!adapter.can_redo_edit());
}

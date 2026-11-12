//! Ported from `Editor/Tests/EditorCoreTests/EditorViewportNavigationTests.swift`.

/// Projection switches preserve focus-plane scale and orthographic pan follows pixels.
#[test]
fn projection_and_navigation() {
    use std::collections::BTreeSet;

    use diffuse_kernel::input_event::KeyModifiers;
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::components::core::registry::ComponentRegistry;
    use diffuse_scene::rendering::render_scene::RenderCameraProjection;

    use crate::editing::viewport::editor_viewport_projection::EditorViewportProjection;
    use crate::rendering::viewport::viewport_host::ViewportScreenFrame;
    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    let frame = ViewportScreenFrame::new(0.0, 0.0, 800.0, 600.0);
    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    adapter.set_editor_viewport_camera_enabled(true);
    adapter.tick_scene_default();
    let perspective = adapter.current_render_camera();
    let projection = EditorViewportProjection::new(perspective, frame).expect("perspective");
    let point = perspective.target + projection.camera_right * 0.5;
    let before = projection.project_default(point).expect("before");

    adapter.set_viewport_projection(RenderCameraProjection::Orthographic);
    let orthographic = adapter.current_render_camera();
    let orthographic_projection =
        EditorViewportProjection::new(orthographic, frame).expect("orthographic");
    let after = orthographic_projection
        .project_default(point)
        .expect("after");
    assert!((after.0 - before.0).abs() < 0.001 && (after.1 - before.1).abs() < 0.001);

    adapter.set_viewport_projection(RenderCameraProjection::Perspective);
    let restored = adapter.current_render_camera();
    assert!(
        (restored.eye.x - perspective.eye.x).abs()
            + (restored.eye.y - perspective.eye.y).abs()
            + (restored.eye.z - perspective.eye.z).abs()
            < 1e-4
    );

    adapter.set_viewport_projection(RenderCameraProjection::Orthographic);
    adapter.pan_camera(60.0, 30.0, frame);
    let moved = EditorViewportProjection::new(adapter.current_render_camera(), frame)
        .expect("moved")
        .project_default(point)
        .expect("moved point");
    assert!((moved.0 - after.0 - 60.0).abs() < 0.001);
    assert!((moved.1 - after.1 - 30.0).abs() < 0.001);

    let panned = adapter.current_render_camera();
    adapter.zoom_camera(0.5);
    let zoomed = adapter.current_render_camera();
    assert_eq!(zoomed.eye, panned.eye);
    assert_eq!(zoomed.target, panned.target);
    assert!((zoomed.orthographic_height - panned.orthographic_height * 0.5).abs() < 1e-5);

    adapter.dolly_camera(20.0);
    assert_eq!(adapter.current_render_camera().eye, zoomed.eye);
    assert!(adapter.current_render_camera().orthographic_height > zoomed.orthographic_height);

    adapter.look_along_axis(Float3::new(0.0, -1.0, 0.0), true);
    adapter.freelook_camera_default(0.0, 0.0, &BTreeSet::new(), KeyModifiers(0));
    assert!(EditorViewportProjection::new(adapter.current_render_camera(), frame).is_some());
}

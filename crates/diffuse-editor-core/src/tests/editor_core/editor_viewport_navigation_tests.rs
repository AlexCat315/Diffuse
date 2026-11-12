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

/// Orthographic point and box picking select offset geometry without a
/// perspective ray.
#[test]
fn orthographic_picking() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::components::core::registry::ComponentRegistry;

    use crate::editing::viewport::editor_viewport_projection::EditorViewportProjection;
    use crate::rendering::viewport::viewport_host::ViewportScreenFrame;
    use crate::scene::adapter::editor_scene_adapter::EditorSceneAdapter;
    use crate::scene::adapter::spawn::EditorEntityTemplate;
    use crate::scene::inspector::rendering::renderers::EditorInspectorRendererRegistry;

    let frame = ViewportScreenFrame::new(0.0, 0.0, 800.0, 600.0);
    let adapter = EditorSceneAdapter::new(
        false,
        ComponentRegistry::built_in(),
        EditorInspectorRendererRegistry::new(),
    );
    adapter.set_editor_viewport_camera_enabled(true);
    adapter.look_along_axis(Float3::new(0.0, 0.0, -1.0), true);
    let first = adapter
        .spawn_entity(EditorEntityTemplate::Cube, None, None)
        .expect("first cube");
    let second = adapter
        .spawn_entity(EditorEntityTemplate::Cube, None, None)
        .expect("second cube");
    adapter.set_entity_local_translation(first, Float3::new(-1.5, 0.0, 0.0));
    adapter.set_entity_local_translation(second, Float3::new(1.5, 0.0, -3.0));
    adapter.tick_scene_default();

    let projection =
        EditorViewportProjection::new(adapter.current_render_camera(), frame).expect("projection");
    let center = projection
        .project(Float3::new(1.5, 0.0, -3.0), true)
        .expect("center");
    assert_eq!(adapter.pick_entity(center.0, center.1, frame), Some(second));
    let selected = adapter.pick_entities(
        ViewportScreenFrame::new(center.0 - 5.0, center.1 - 5.0, 10.0, 10.0),
        frame,
    );
    assert_eq!(selected, std::collections::BTreeSet::from([second]));
}

// 其余用例在下方追加。

/// Orthographic gizmo drag follows the cursor and applies configurable
/// translation snapping.
#[test]
fn orthographic_gizmo_drag() {
    use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};
    use diffuse_scene::rendering::render_scene::{RenderCamera, RenderCameraProjection};

    use crate::editing::editor_gizmo_controller::{
        EditorGizmoController, GizmoAxis, GizmoMode, GizmoSnapshot, GizmoSpace,
    };
    use crate::editing::editor_transform_snapping::EditorTransformSnapping;
    use crate::rendering::viewport::viewport_host::ViewportScreenFrame;
    use crate::state::editor_state::EditorState;
    use crate::state::viewports::editor_snapping_state::EditorSnappingState;

    let frame = ViewportScreenFrame::new(0.0, 0.0, 800.0, 600.0);
    let camera = RenderCamera {
        eye: Float3::new(0.0, 0.0, 5.0),
        target: Float3::ZERO,
        projection: RenderCameraProjection::Orthographic,
        orthographic_height: 6.0,
        ..RenderCamera::new(Float3::new(0.0, 0.0, 5.0), Float3::ZERO)
    };
    let controller = EditorGizmoController::new();
    controller.update_snapshot(Some(GizmoSnapshot::new(
        GizmoMode::Translate,
        GizmoSpace::World,
        camera,
        frame,
        1,
        Float3::ZERO,
        MATRIX_IDENTITY_FLOAT4X4,
        MATRIX_IDENTITY_FLOAT4X4,
        MATRIX_IDENTITY_FLOAT4X4,
        1.0,
    )));
    let drag = controller
        .begin_drag_default(450.0, 300.0)
        .expect("begin drag");
    assert_eq!(drag.axis, GizmoAxis::X);
    let matrix = controller.update_drag(513.0, 300.0).expect("drag");
    assert!((matrix.columns[3].x - 0.63).abs() < 1e-4);

    let state = EditorState {
        snapping: EditorSnappingState::with_configure(|snapping| {
            snapping.translate_snap_enabled = true;
            snapping.translate_snap_step = 0.25;
        }),
        ..EditorState::default()
    };
    let snapped = EditorTransformSnapping::apply(matrix, GizmoMode::Translate, &state);
    assert_eq!(snapped.columns[3].x, 0.75);
}

/// Gizmo keeps its screen size and supports picking and dragging beyond the
/// far plane.
#[test]
fn distant_gizmo() {
    use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};
    use diffuse_scene::rendering::render_scene::{RenderCamera, RenderCameraProjection};

    use crate::editing::editor_gizmo_controller::{
        EditorGizmoController, GizmoAxis, GizmoMode, GizmoSnapshot, GizmoSpace, ScreenProjector,
    };
    use crate::editing::viewport::editor_viewport_projection::EditorViewportProjection;
    use crate::rendering::viewport::viewport_host::ViewportScreenFrame;

    let frame = ViewportScreenFrame::new(0.0, 0.0, 800.0, 600.0);
    for projection in [
        RenderCameraProjection::Perspective,
        RenderCameraProjection::Orthographic,
    ] {
        for distance in [5.0f32, 500.0, 50_000.0] {
            let camera = RenderCamera {
                eye: Float3::new(0.0, 0.0, distance),
                fov_y_radians: core::f32::consts::PI / 3.0,
                projection,
                orthographic_height: distance,
                ..RenderCamera::new(Float3::new(0.0, 0.0, distance), Float3::ZERO)
            };
            let length =
                EditorGizmoController::axis_length_default(&camera, Float3::ZERO, frame.height);
            let snapshot = GizmoSnapshot::new(
                GizmoMode::Translate,
                GizmoSpace::World,
                camera,
                frame,
                1,
                Float3::ZERO,
                MATRIX_IDENTITY_FLOAT4X4,
                MATRIX_IDENTITY_FLOAT4X4,
                MATRIX_IDENTITY_FLOAT4X4,
                length,
            );
            let projector = ScreenProjector::new(&snapshot).expect("projector");
            let tip = projector
                .project(Float3::new(length, 0.0, 0.0))
                .expect("tip");
            assert!((tip.0 - 496.0).abs() < 0.01 && (tip.1 - 300.0).abs() < 0.01);
            assert!(
                projector
                    .project(camera.eye + Float3::new(0.0, 0.0, 1.0))
                    .is_none()
            );

            let scene_projection = EditorViewportProjection::new(camera, frame).expect("scene");
            if distance > camera.far {
                assert!(scene_projection.project(Float3::ZERO, true).is_none());
            }

            let controller = EditorGizmoController::new();
            controller.update_snapshot(Some(snapshot));
            let drag = controller
                .begin_drag_default(tip.0 - 4.0, tip.1)
                .expect("begin beyond far plane");
            assert_eq!(drag.axis, GizmoAxis::X);
            let moved = controller
                .update_drag(tip.0 + 20.0, tip.1)
                .expect("move beyond far plane");
            assert!((moved.columns[3].x / length - 0.25).abs() < 0.001);
        }
    }
}

/// Gizmo screen size accounts for field of view, viewport height, and
/// off-center pivots.
#[test]
fn gizmo_projection_scale() {
    use diffuse_math::simd::simd_compat::Float3;
    use diffuse_scene::rendering::render_scene::RenderCamera;

    use crate::editing::editor_gizmo_controller::EditorGizmoController;
    use crate::editing::viewport::editor_viewport_projection::EditorViewportProjection;
    use crate::rendering::viewport::viewport_host::ViewportScreenFrame;

    for fov in [core::f32::consts::PI / 6.0, core::f32::consts::PI / 2.0] {
        for height in [300.0f32, 1200.0] {
            let camera = RenderCamera {
                fov_y_radians: fov,
                ..RenderCamera::new(Float3::new(0.0, 0.0, 500.0), Float3::ZERO)
            };
            let pivot = Float3::new(200.0, 0.0, 0.0);
            let frame = ViewportScreenFrame::new(40.0, 20.0, 1600.0, height);
            let projection = EditorViewportProjection::new(camera, frame).expect("projection");
            let length = EditorGizmoController::axis_length_default(&camera, pivot, height);
            let origin = projection.project(pivot, false).expect("origin");
            let tip = projection
                .project(pivot + Float3::new(length, 0.0, 0.0), false)
                .expect("tip");
            assert!((tip.0 - origin.0 - 96.0).abs() < 0.01);
        }
    }
}

/// Custom rotation and scale steps preserve the other transform components.
#[test]
fn rotation_and_scale_steps() {
    use diffuse_math::simd::simd_compat::{Float3, Float4, Quatf, simd_length};
    use diffuse_scene::runtime_world::LocalTransform;

    use crate::editing::editor_gizmo_controller::GizmoMode;
    use crate::editing::editor_transform_snapping::EditorTransformSnapping;
    use crate::state::editor_state::EditorState;
    use crate::state::viewports::editor_snapping_state::EditorSnappingState;

    let angle = 22.0f32 * core::f32::consts::PI / 180.0;
    let mut matrix = LocalTransform::from_rotation_scale(
        Quatf::from_angle_axis(angle, Float3::new(0.0, 0.0, 1.0)),
        Float3::ONE,
    )
    .matrix;
    matrix.set_column(0, matrix.columns[0] * 1.23);
    matrix.set_column(1, matrix.columns[1] * 1.44);
    matrix.set_column(2, matrix.columns[2] * 0.84);
    matrix.set_column(3, Float4::new(3.0, -2.0, 5.0, 1.0));

    let state = EditorState {
        snapping: EditorSnappingState::with_configure(|snapping| {
            snapping.rotate_snap_enabled = true;
            snapping.scale_snap_enabled = true;
            snapping.rotate_snap_step_degrees = 15.0;
            snapping.scale_snap_step = 0.2;
        }),
        ..EditorState::default()
    };

    let rotated = EditorTransformSnapping::apply(matrix, GizmoMode::Rotate, &state);
    assert!(
        (rotated.columns[0].y.atan2(rotated.columns[0].x) - core::f32::consts::PI / 12.0).abs()
            < 1e-4
    );
    assert_eq!(rotated.columns[3], matrix.columns[3]);
    let len = |column: Float4| simd_length(Float3::new(column.x, column.y, column.z));
    assert!((len(rotated.columns[0]) - 1.23).abs() < 1e-4);

    let scaled = EditorTransformSnapping::apply(matrix, GizmoMode::Scale, &state);
    assert!((len(scaled.columns[0]) - 1.2).abs() < 1e-4);
    assert!((len(scaled.columns[1]) - 1.4).abs() < 1e-4);
    assert_eq!(scaled.columns[3], matrix.columns[3]);
    assert!((scaled.columns[0].y.atan2(scaled.columns[0].x) - angle).abs() < 1e-4);
    assert_eq!(
        EditorTransformSnapping::apply(matrix, GizmoMode::Scale, &EditorState::default()),
        matrix
    );
}

/// Snap steps round-trip, default missing fields, and reject invalid values.
#[test]
fn snap_state_validation() {
    use crate::state::editor_reducer::{EditorAction, EditorReducer};
    use crate::state::editor_state::EditorState;
    use crate::state::viewports::editor_snapping_state::EditorSnappingState;

    let mut state = EditorState {
        snapping: EditorSnappingState::with_configure(|snapping| {
            snapping.translate_snap_step = 0.125;
            snapping.rotate_snap_step_degrees = 30.0;
            snapping.scale_snap_step = 0.01;
        }),
        ..EditorState::default()
    };
    let data = serde_json::to_vec(&state).expect("encode state");
    let restored: EditorState = serde_json::from_slice(&data).expect("decode state");
    assert_eq!(restored.snapping.translate_snap_step, 0.125);
    assert_eq!(restored.snapping.rotate_snap_step_degrees, 30.0);
    assert_eq!(restored.snapping.scale_snap_step, 0.01);

    let mut object: serde_json::Value = serde_json::from_slice(&data).expect("json object");
    let snapping = object
        .get_mut("snapping")
        .and_then(serde_json::Value::as_object_mut)
        .expect("snapping object");
    for key in [
        "translateSnapStep",
        "rotateSnapStepDegrees",
        "scaleSnapStep",
    ] {
        snapping.remove(key);
    }
    let defaults: EditorState =
        serde_json::from_slice(&serde_json::to_vec(&object).expect("json")).expect("defaults");
    assert_eq!(defaults.snapping.translate_snap_step, 0.5);
    assert_eq!(defaults.snapping.rotate_snap_step_degrees, 5.0);
    assert_eq!(defaults.snapping.scale_snap_step, 0.05);

    EditorReducer::reduce(&mut state, EditorAction::SetTranslateSnapStep(f32::NAN));
    EditorReducer::reduce(&mut state, EditorAction::SetRotateSnapStepDegrees(500.0));
    EditorReducer::reduce(&mut state, EditorAction::SetScaleSnapStep(0.0001));
    assert_eq!(state.snapping.translate_snap_step, 0.5);
    assert_eq!(state.snapping.rotate_snap_step_degrees, 180.0);
    assert_eq!(state.snapping.scale_snap_step, 0.001);
}

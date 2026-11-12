//! Ported from `Editor/Tests/EditorCoreTests/EditorViewportProjectionTests.swift`.

use std::f32::consts::PI;

use diffuse_math::simd::simd_compat::{
    Float3, simd_cross, simd_distance, simd_length, simd_normalize,
};
use diffuse_scene::rendering::render_scene::{RenderCamera, RenderCameraProjection};

use crate::editing::viewport::editor_viewport_projection::{
    EditorViewportFraming, EditorViewportProjection,
};
use crate::rendering::viewport::viewport_host::ViewportScreenFrame;

fn frame(width: f32, height: f32) -> ViewportScreenFrame {
    ViewportScreenFrame::new(0.0, 0.0, width, height)
}

fn make_projection() -> EditorViewportProjection {
    let camera = RenderCamera::with_parameters(
        Float3::new(0.0, 0.0, 5.0),
        Float3::ZERO,
        Float3::new(0.0, 1.0, 0.0),
        PI / 4.0,
        1.0,
        0.1,
        100.0,
        RenderCameraProjection::Perspective,
        10.0,
    );
    EditorViewportProjection::new(camera, frame(800.0, 600.0)).expect("projection")
}

/// Orthographic picking rays are parallel, offset, and round-trip at every depth.
#[test]
fn orthographic_parallel_rays() {
    let camera = RenderCamera::with_parameters(
        Float3::new(0.0, 0.0, 5.0),
        Float3::ZERO,
        Float3::new(0.0, 1.0, 0.0),
        PI / 4.0,
        1.0,
        0.1,
        100.0,
        RenderCameraProjection::Orthographic,
        6.0,
    );
    let projection =
        EditorViewportProjection::new(camera, ViewportScreenFrame::new(40.0, 20.0, 800.0, 600.0))
            .expect("orthographic projection");
    let left = projection.cursor_ray(240.0, 320.0);
    let right = projection.cursor_ray(640.0, 320.0);
    assert_eq!(left.1, Float3::new(0.0, 0.0, -1.0));
    assert_eq!(left.1, right.1);
    assert!((right.0.x - left.0.x - 4.0).abs() < 1e-5);
    assert!((left.0.z - 4.9).abs() < 1e-5);
    let near_point = projection
        .project_default(Float3::new(1.5, -0.8, 0.0))
        .expect("near point");
    let far_point = projection
        .project_default(Float3::new(1.5, -0.8, -40.0))
        .expect("far point");
    assert!((near_point.0 - far_point.0).abs() < 1e-5);
    assert!((near_point.1 - far_point.1).abs() < 1e-5);
    let ray = projection.cursor_ray(near_point.0, near_point.1);
    assert!((ray.0.x - 1.5).abs() < 1e-5 && (ray.0.y + 0.8).abs() < 1e-5);
    assert!(
        projection
            .project_default(Float3::new(0.0, 0.0, 4.95))
            .is_none()
    );
    assert!(
        projection
            .project_default(Float3::new(0.0, 0.0, -100.0))
            .is_none()
    );
}

/// Orthographic framing fits bounds even in a narrow viewport.
#[test]
fn orthographic_framing_fits() {
    let mut camera = RenderCamera::with_parameters(
        Float3::new(6.0, 5.0, 8.0),
        Float3::ZERO,
        Float3::new(0.0, 1.0, 0.0),
        PI / 4.0,
        1.0,
        0.1,
        100.0,
        RenderCameraProjection::Orthographic,
        1.0,
    );
    let lower = Float3::new(-2.0, -1.0, -3.0);
    let upper = Float3::new(4.0, 5.0, 1.0);
    let pose = EditorViewportFraming::pose(&camera, lower, upper, Some(0.5), 1.3);
    camera.eye = pose.eye;
    camera.target = pose.target;
    camera.up = pose.up;
    camera.orthographic_height = pose.orthographic_height.expect("orthographic height");
    let projection =
        EditorViewportProjection::new(camera, ViewportScreenFrame::new(0.0, 0.0, 400.0, 800.0))
            .expect("projection");
    for x in [lower.x, upper.x] {
        for y in [lower.y, upper.y] {
            for z in [lower.z, upper.z] {
                let screen = projection
                    .project_default(Float3::new(x, y, z))
                    .expect("corner");
                assert!(screen.0 >= 20.0 && screen.0 <= 380.0);
                assert!(screen.1 >= 40.0 && screen.1 <= 760.0);
            }
        }
    }
}

/// Degenerate frame or camera fails to construct.
#[test]
fn degenerate_inits_fail() {
    let camera = RenderCamera::new(Float3::ZERO, Float3::ZERO);
    assert!(EditorViewportProjection::new(camera, frame(800.0, 600.0)).is_none());

    let ok = RenderCamera::new(Float3::new(0.0, 0.0, 5.0), Float3::ZERO);
    assert!(EditorViewportProjection::new(ok, frame(0.0, 600.0)).is_none());
}

/// Camera target projects to the screen center.
#[test]
fn target_projects_to_center() {
    let projection = make_projection();
    let screen = projection.project_default(Float3::ZERO).expect("screen");
    assert!((screen.0 - 400.0).abs() < 0.5);
    assert!((screen.1 - 300.0).abs() < 0.5);
}

/// A point behind the camera does not project.
#[test]
fn point_behind_camera_returns_none() {
    let projection = make_projection();
    assert!(
        projection
            .project_default(Float3::new(0.0, 0.0, 10.0))
            .is_none()
    );
}

/// Center cursor ray points along the camera forward axis.
#[test]
fn center_ray_matches_forward() {
    let projection = make_projection();
    let ray = projection.cursor_ray(400.0, 300.0);
    assert!(simd_distance(ray.0, Float3::new(0.0, 0.0, 5.0)) < 1e-5);
    assert!(simd_distance(ray.1, Float3::new(0.0, 0.0, -1.0)) < 1e-4);
}

/// Project then cursorRay round-trips through the same screen point.
#[test]
fn project_cursor_ray_round_trip() {
    let projection = make_projection();
    let world = Float3::new(1.5, -0.8, 0.0);
    let screen = projection.project_default(world).expect("screen");
    let ray = projection.cursor_ray(screen.0, screen.1);
    let to_point = simd_normalize(world - ray.0);
    assert!(simd_distance(to_point, simd_normalize(ray.1)) < 1e-3);
}

/// Cursor ray tilts right for pixels right of center.
#[test]
fn ray_tilts_with_cursor() {
    let projection = make_projection();
    let left = projection.cursor_ray(200.0, 300.0);
    let right = projection.cursor_ray(600.0, 300.0);
    assert!(right.1.x > left.1.x);
}

/// Framing centers and safely fits every world-bounds corner.
#[test]
fn framing_fits_world_bounds() {
    let bounds_min = Float3::new(-1.5, -3.0, -0.75);
    let bounds_max = Float3::new(2.5, 5.0, 1.25);
    let aspect = 16.0 / 9.0;
    let source = RenderCamera::with_parameters(
        Float3::new(8.0, 5.0, 11.0),
        Float3::new(1.0, 1.0, 0.0),
        Float3::new(0.0, 1.0, 0.0),
        PI / 4.0,
        aspect,
        0.1,
        500.0,
        RenderCameraProjection::Perspective,
        10.0,
    );
    let pose = EditorViewportFraming::pose(&source, bounds_min, bounds_max, Some(aspect), 1.3);
    let expected_center = (bounds_min + bounds_max) * 0.5;
    assert!(simd_distance(pose.target, expected_center) < 1e-5);

    let mut framed = source;
    framed.eye = pose.eye;
    framed.target = pose.target;
    framed.up = pose.up;
    let projection =
        EditorViewportProjection::new(framed, frame(1600.0, 900.0)).expect("projection");
    for x in [bounds_min.x, bounds_max.x] {
        for y in [bounds_min.y, bounds_max.y] {
            for z in [bounds_min.z, bounds_max.z] {
                let screen = projection
                    .project_default(Float3::new(x, y, z))
                    .expect("corner");
                assert!(screen.0 >= 80.0 && screen.0 <= 1520.0);
                assert!(screen.1 >= 45.0 && screen.1 <= 855.0);
            }
        }
    }
}

/// Framing honors a narrow viewport and repairs a degenerate camera.
#[test]
fn framing_handles_narrow_viewport_and_degenerate_camera() {
    let bounds_min = Float3::new(-2.0, -1.0, -1.0);
    let bounds_max = Float3::new(2.0, 1.0, 1.0);
    let camera = RenderCamera::with_parameters(
        Float3::ZERO,
        Float3::ZERO,
        Float3::new(0.0, 1.0, 0.0),
        PI / 3.0,
        1.0,
        0.1,
        100.0,
        RenderCameraProjection::Perspective,
        10.0,
    );
    let pose = EditorViewportFraming::pose(&camera, bounds_min, bounds_max, Some(0.5), 1.3);
    assert!(pose.eye.x.is_finite() && pose.eye.y.is_finite() && pose.eye.z.is_finite());
    assert!(simd_distance(pose.eye, pose.target) > 4.0);

    let mut framed = camera;
    framed.eye = pose.eye;
    framed.target = pose.target;
    framed.up = pose.up;
    let projection =
        EditorViewportProjection::new(framed, ViewportScreenFrame::new(0.0, 0.0, 400.0, 800.0))
            .expect("projection");
    for x in [bounds_min.x, bounds_max.x] {
        for y in [bounds_min.y, bounds_max.y] {
            for z in [bounds_min.z, bounds_max.z] {
                let screen = projection
                    .project_default(Float3::new(x, y, z))
                    .expect("corner");
                assert!(screen.0 >= 20.0 && screen.0 <= 380.0);
                assert!(screen.1 >= 40.0 && screen.1 <= 760.0);
            }
        }
    }
}

/// Framing repairs an up vector parallel to the view direction.
#[test]
fn framing_repairs_parallel_up_vector() {
    let camera = RenderCamera::with_parameters(
        Float3::new(0.0, 5.0, 0.0),
        Float3::ZERO,
        Float3::new(0.0, 1.0, 0.0),
        PI / 3.0,
        1.0,
        0.1,
        100.0,
        RenderCameraProjection::Perspective,
        10.0,
    );
    let pose = EditorViewportFraming::pose(
        &camera,
        Float3::new(-1.0, -1.0, -1.0),
        Float3::new(1.0, 1.0, 1.0),
        None,
        1.3,
    );
    let forward = simd_normalize(pose.target - pose.eye);
    assert!(pose.up.x.is_finite() && pose.up.y.is_finite() && pose.up.z.is_finite());
    assert!((simd_length(pose.up) - 1.0).abs() < 1e-5);
    assert!(simd_length(simd_cross(forward, pose.up)) > 0.1);

    let mut framed = camera;
    framed.eye = pose.eye;
    framed.target = pose.target;
    framed.up = pose.up;
    assert!(EditorViewportProjection::new(framed, frame(800.0, 600.0)).is_some());
}

/// Framing turns non-finite bounds into a safe finite pose.
#[test]
fn framing_repairs_non_finite_bounds() {
    let camera = RenderCamera::new(Float3::new(0.0, 0.0, 5.0), Float3::ZERO);
    let pose = EditorViewportFraming::pose(
        &camera,
        Float3::new(f32::NAN, f32::NEG_INFINITY, 1.0),
        Float3::new(f32::INFINITY, 2.0, f32::NAN),
        None,
        1.3,
    );
    assert!(pose.eye.x.is_finite() && pose.eye.y.is_finite() && pose.eye.z.is_finite());
    assert_eq!(pose.target, Float3::ZERO);
    assert!(simd_distance(pose.eye, pose.target) > 0.0);
}

//! `CameraMatricesTests` — Swift suite `CameraMatrices`.

use diffuse_math::camera::camera_matrices::CameraMatrices;
use diffuse_math::simd::simd_compat::{Float3, Float4, simd_distance4};

// "orthographic projection maps its visible rectangle and depth to clip space"
#[test]
fn orthographic_clip_convention() {
    let projection = CameraMatrices::orthographic_rh_zo(6.0, 2.0, 0.5, 20.0);
    let near_corner = projection * Float4::new(6.0, 3.0, -0.5, 1.0);
    let far_corner = projection * Float4::new(-6.0, -3.0, -20.0, 1.0);
    assert!(simd_distance4(near_corner, Float4::new(1.0, 1.0, 0.0, 1.0)) < 1e-5);
    assert!(simd_distance4(far_corner, Float4::new(-1.0, -1.0, 1.0, 1.0)) < 1e-5);
    let shallow = projection * Float4::new(2.0, 1.0, -2.0, 1.0);
    let deep = projection * Float4::new(2.0, 1.0, -15.0, 1.0);
    assert!(shallow.x == deep.x && shallow.y == deep.y && shallow.w == deep.w);
}

// "perspectiveRH_ZO matches renderer projection convention"
#[test]
fn perspective_matches_renderer_convention() {
    let projection =
        CameraMatrices::perspective_rh_zo(core::f32::consts::PI / 2.0, 1.0, 0.1, 100.0);

    assert!((projection.columns[0].x - 1.0).abs() < 0.000_001);
    assert!((projection.columns[1].y - 1.0).abs() < 0.000_001);
    assert!((projection.columns[2].z - (-1.001_001)).abs() < 0.000_001);
    assert!((projection.columns[3].z - (-0.100_100_1)).abs() < 0.000_001);
    assert!(projection.columns[2].w == -1.0);
}

// "lookAtRH places the camera at the origin in view space"
#[test]
fn look_at_places_eye_at_origin() {
    let eye = Float3::new(0.0, 3.0, 8.0);
    let view =
        CameraMatrices::look_at_rh(eye, Float3::new(0.0, 0.0, 0.0), Float3::new(0.0, 1.0, 0.0));
    let transformed_eye = view * Float4::new(eye.x, eye.y, eye.z, 1.0);

    assert!(transformed_eye.x.abs() < 0.000_001);
    assert!(transformed_eye.y.abs() < 0.000_001);
    assert!(transformed_eye.z.abs() < 0.000_001);
    assert!(transformed_eye.w == 1.0);
}

//! `Transform3DTests` — Swift suite `Transform3D`.

use diffuse_math::simd::simd_compat::{Float3, Float4, Quatf, cove_slerp, simd_dot4, simd_length4};
use diffuse_math::transforms::transform_3d::Transform3D;
use diffuse_math::utility::float_comparisons::FloatComparisons;

// "transform composes translation rotation and scale into a matrix"
#[test]
fn transform_composes_matrix() {
    let transform = Transform3D::new(
        Float3::new(3.0, 0.0, 0.0),
        Quatf::from_angle_axis(core::f32::consts::PI / 2.0, Float3::new(0.0, 0.0, 1.0)),
        Float3::new(2.0, 2.0, 2.0),
    );
    let point = transform.matrix() * Float4::new(1.0, 0.0, 0.0, 1.0);

    assert!(FloatComparisons::nearly_equal_default(
        Float3::new(point.x, point.y, point.z),
        Float3::new(3.0, 2.0, 0.0)
    ));
}

// "transform exposes point transform and inverse matrix"
#[test]
fn transform_exposes_point_transform_and_inverse() {
    let transform = Transform3D::new(
        Float3::new(5.0, -2.0, 1.0),
        Quatf::from_angle_axis(0.0, Float3::new(0.0, 1.0, 0.0)),
        Float3::new(2.0, 2.0, 2.0),
    );
    let world = transform.transform_point(Float3::new(1.0, 2.0, 3.0));
    let local4 = transform.inverse_matrix() * Float4::new(world.x, world.y, world.z, 1.0);

    assert_eq!(world, Float3::new(7.0, 2.0, 7.0));
    assert!(FloatComparisons::nearly_equal_default(
        Float3::new(local4.x, local4.y, local4.z),
        Float3::new(1.0, 2.0, 3.0)
    ));
}

// "quaternion slerp follows the shortest normalized arc"
#[test]
fn quaternion_slerp_uses_shortest_arc() {
    let start = Quatf::from_angle_axis(0.0, Float3::new(0.0, 1.0, 0.0));
    let end = Quatf::from_angle_axis(core::f32::consts::PI / 2.0, Float3::new(0.0, 1.0, 0.0));
    let expected = Quatf::from_angle_axis(core::f32::consts::PI / 4.0, Float3::new(0.0, 1.0, 0.0));

    let midpoint = cove_slerp(start, end, 0.5);

    assert!(simd_dot4(midpoint.vector, expected.vector).abs() > 0.9999);
    assert!((simd_length4(midpoint.vector) - 1.0).abs() < 0.0001);
}

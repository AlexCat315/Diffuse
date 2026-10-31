//! `Plane3DTests` — Swift suite `Plane3D`.

use diffuse_math::bounds::bounds_3d::Bounds3D;
use diffuse_math::geometry::plane_3d::Plane3D;
use diffuse_math::simd::simd_compat::Float3;

// "plane computes signed point distances"
#[test]
fn plane_computes_signed_point_distances() {
    let plane = Plane3D::from_point(Float3::new(0.0, 2.0, 0.0), Float3::new(0.0, 3.0, 0.0));

    assert_eq!(plane.normal, Float3::new(0.0, 1.0, 0.0));
    assert_eq!(plane.signed_distance(Float3::new(0.0, 5.0, 0.0)), 2.0);
    assert_eq!(plane.signed_distance(Float3::new(0.0, 1.0, 0.0)), -2.0);
}

// "plane computes conservative bounds distances"
#[test]
fn plane_computes_bounds_distances() {
    let plane = Plane3D::new(Float3::new(1.0, 0.0, 0.0), -2.0, true);
    let bounds = Bounds3D::new(Float3::new(1.0, -1.0, -1.0), Float3::new(4.0, 1.0, 1.0));

    assert_eq!(plane.min_signed_distance(bounds), -1.0);
    assert_eq!(plane.max_signed_distance(bounds), 2.0);
}

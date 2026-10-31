//! `Ray3DTests` — Swift suite `Ray3D`.

use diffuse_math::bounds::bounds_3d::Bounds3D;
use diffuse_math::geometry::ray_3d::Ray3D;
use diffuse_math::simd::simd_compat::Float3;

// "ray normalizes direction and samples points"
#[test]
fn ray_normalizes_direction_and_samples_points() {
    let ray = Ray3D::normalized(Float3::new(1.0, 2.0, 3.0), Float3::new(0.0, 0.0, -5.0));

    assert_eq!(ray.direction, Float3::new(0.0, 0.0, -1.0));
    assert_eq!(ray.point_at(4.0), Float3::new(1.0, 2.0, -1.0));
}

// "ray intersects bounds with nearest positive distance"
#[test]
fn ray_intersects_bounds() {
    let bounds = Bounds3D::new(Float3::new(-1.0, -1.0, -1.0), Float3::new(1.0, 1.0, 1.0));
    let ray = Ray3D::normalized(Float3::new(0.0, 0.0, 5.0), Float3::new(0.0, 0.0, -1.0));
    let miss = Ray3D::normalized(Float3::new(3.0, 0.0, 5.0), Float3::new(0.0, 0.0, -1.0));

    assert_eq!(ray.distance_to_bounds(bounds), Some(4.0));
    assert_eq!(miss.distance_to_bounds(bounds), None);
    assert_eq!(
        Ray3D::normalized(Float3::ZERO, Float3::new(1.0, 0.0, 0.0)).distance_to_bounds(bounds),
        Some(0.0)
    );
}

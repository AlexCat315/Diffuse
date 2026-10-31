//! `Frustum3DTests` — Swift suite `Frustum3D`.

use diffuse_math::bounds::bounds_3d::Bounds3D;
use diffuse_math::geometry::frustum_3d::Frustum3D;
use diffuse_math::simd::simd_compat::{Float3, MATRIX_IDENTITY_FLOAT4X4};

// "frustum tests spheres and bounds"
#[test]
fn frustum_tests_spheres_and_bounds() {
    let frustum = Frustum3D::from_view_projection(MATRIX_IDENTITY_FLOAT4X4);

    assert!(frustum.contains_sphere(Float3::new(0.0, 0.0, 0.5), 0.25));
    assert!(!frustum.contains_sphere(Float3::new(3.0, 0.0, 0.5), 0.25));
    assert!(frustum.intersects(Bounds3D::new(
        Float3::new(-0.5, -0.5, 0.25),
        Float3::new(0.5, 0.5, 0.75)
    )));
    assert!(!frustum.intersects(Bounds3D::new(
        Float3::new(2.0, 2.0, 2.0),
        Float3::new(3.0, 3.0, 3.0)
    )));
}

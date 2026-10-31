//! `Bounds3DTests` — Swift suite `Bounds3D`.

use diffuse_math::bounds::bounds_3d::Bounds3D;
use diffuse_math::simd::simd_compat::{Float3, Float4, Float4x4};

// "bounds expose center and extents"
#[test]
fn bounds_expose_center_and_extents() {
    let bounds = Bounds3D::new(Float3::new(-1.0, 2.0, 4.0), Float3::new(3.0, 6.0, 10.0));

    assert_eq!(bounds.center(), Float3::new(1.0, 4.0, 7.0));
    assert_eq!(bounds.extent(), Float3::new(4.0, 4.0, 6.0));
    assert_eq!(bounds.half_extent(), Float3::new(2.0, 2.0, 3.0));
}

// "bounds can be built from point sequences"
#[test]
fn bounds_can_be_built_from_point_sequences() {
    let bounds = Bounds3D::from_points([
        Float3::new(2.0, -1.0, 4.0),
        Float3::new(-3.0, 5.0, 1.0),
        Float3::new(0.0, 2.0, 9.0),
    ]);

    assert!(!bounds.is_empty());
    assert_eq!(bounds.min, Float3::new(-3.0, -1.0, 1.0));
    assert_eq!(bounds.max, Float3::new(2.0, 5.0, 9.0));
    assert!(Bounds3D::EMPTY.is_empty());
}

// "bounds contain points and clamp to closest point"
#[test]
fn bounds_contain_points_and_clamp() {
    let bounds = Bounds3D::new(Float3::new(-1.0, 0.0, 2.0), Float3::new(3.0, 4.0, 6.0));

    assert!(bounds.contains(Float3::new(1.0, 2.0, 3.0)));
    assert!(!bounds.contains(Float3::new(4.0, 2.0, 3.0)));
    assert_eq!(
        bounds.closest_point(Float3::new(6.0, -2.0, 4.0)),
        Float3::new(3.0, 0.0, 4.0)
    );
    assert!(!Bounds3D::EMPTY.contains(Float3::ZERO));
}

// "bounds support union and intersection"
#[test]
fn bounds_support_union_and_intersection() {
    let a = Bounds3D::new(Float3::new(0.0, 0.0, 0.0), Float3::new(3.0, 3.0, 3.0));
    let b = Bounds3D::new(Float3::new(2.0, -1.0, 1.0), Float3::new(4.0, 2.0, 5.0));
    let union = a.union(b);
    let intersection = a.intersection(b).expect("bounds must intersect");

    assert_eq!(union.min, Float3::new(0.0, -1.0, 0.0));
    assert_eq!(union.max, Float3::new(4.0, 3.0, 5.0));
    assert_eq!(intersection.min, Float3::new(2.0, 0.0, 1.0));
    assert_eq!(intersection.max, Float3::new(3.0, 2.0, 3.0));
    assert!(a.intersects(b));
    assert!(!a.intersects(Bounds3D::new(
        Float3::new(5.0, 5.0, 5.0),
        Float3::new(6.0, 6.0, 6.0)
    )));
}

// "bounds can expand uniformly or per axis"
#[test]
fn bounds_can_expand() {
    let bounds = Bounds3D::new(Float3::new(1.0, 2.0, 3.0), Float3::new(4.0, 5.0, 6.0));
    let uniform = bounds.expanded_scalar(1.0);
    let per_axis = bounds.expanded(Float3::new(1.0, 2.0, 3.0));

    assert_eq!(uniform.min, Float3::new(0.0, 1.0, 2.0));
    assert_eq!(uniform.max, Float3::new(5.0, 6.0, 7.0));
    assert_eq!(per_axis.min, Float3::new(0.0, 0.0, 0.0));
    assert_eq!(per_axis.max, Float3::new(5.0, 7.0, 9.0));
    assert!(Bounds3D::EMPTY.expanded_scalar(10.0).is_empty());
}

// "bounds transform by matrices"
#[test]
fn bounds_transform_by_matrices() {
    let bounds = Bounds3D::new(Float3::new(-1.0, -2.0, -3.0), Float3::new(1.0, 2.0, 3.0));
    let transform = Float4x4::from_rows(&[
        Float4::new(2.0, 0.0, 0.0, 4.0),
        Float4::new(0.0, 3.0, 0.0, -5.0),
        Float4::new(0.0, 0.0, 1.0, 6.0),
        Float4::new(0.0, 0.0, 0.0, 1.0),
    ]);
    let transformed = bounds.transformed(transform);

    assert_eq!(transformed.min, Float3::new(2.0, -11.0, 3.0));
    assert_eq!(transformed.max, Float3::new(6.0, 1.0, 9.0));
}

//! `MatrixTransformsTests` — Swift suite `MatrixTransforms`.

use diffuse_math::simd::simd_compat::{Float3, Float4};
use diffuse_math::transforms::matrix_transforms::MatrixTransforms;
use diffuse_math::utility::float_comparisons::FloatComparisons;

// "translation and scale transform points"
#[test]
fn translation_and_scale_transform_points() {
    let point = Float4::new(1.0, 2.0, 3.0, 1.0);
    let translated = MatrixTransforms::translation(Float3::new(4.0, -2.0, 1.0)) * point;
    let scaled = MatrixTransforms::scale(Float3::new(2.0, 3.0, 4.0)) * point;

    assert_eq!(translated, Float4::new(5.0, 0.0, 4.0, 1.0));
    assert_eq!(scaled, Float4::new(2.0, 6.0, 12.0, 1.0));
}

// "axis rotations transform directions"
#[test]
fn axis_rotations_transform_directions() {
    let rotated =
        MatrixTransforms::rotation(Float3::new(0.0, 0.0, 1.0), core::f32::consts::PI / 2.0)
            * Float4::new(1.0, 0.0, 0.0, 0.0);

    assert!(FloatComparisons::nearly_equal_default(
        Float3::new(rotated.x, rotated.y, rotated.z),
        Float3::new(0.0, 1.0, 0.0)
    ));
}

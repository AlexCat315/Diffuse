//! Ported from `Engine/Tests/SceneRuntimeTests/LocalTransformConvenienceTests.swift`.
//!
//! Swift's `transform.translation` setter writes column 3 only, leaving the
//! rotation/scale basis untouched; Rust spells that as `set_translation`.

use diffuse_math::simd::simd_compat::Quatf;
use diffuse_math::simd::simd_compat::{Float3, Float4};

use crate::runtime_world::LocalTransform;

/// Translation edits preserve rotated nonuniform scale.
#[test]
fn edits_translation() {
    let rotation = Quatf::from_angle_axis(std::f32::consts::FRAC_PI_2, Float3::new(0.0, 1.0, 0.0));
    let mut transform = LocalTransform::from_translation_rotation_scale(
        Float3::new(1.0, 2.0, 3.0),
        rotation,
        Float3::new(2.0, 3.0, 4.0),
    );
    let basis = transform.matrix;
    let point = transform.matrix * Float4::new(1.0, 0.0, 0.0, 1.0);
    assert!((point.x - 1.0).abs() < 0.0001);
    assert!((point.z - 1.0).abs() < 0.0001);

    transform.set_translation(Float3::new(9.0, 8.0, 7.0));
    assert_eq!(transform.matrix.columns[0], basis.columns[0]);
    assert_eq!(transform.matrix.columns[1], basis.columns[1]);
    assert_eq!(transform.matrix.columns[2], basis.columns[2]);
    assert_eq!(transform.translation(), Float3::new(9.0, 8.0, 7.0));
}

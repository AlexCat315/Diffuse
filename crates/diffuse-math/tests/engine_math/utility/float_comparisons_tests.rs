//! `FloatComparisonsTests` — Swift suite `FloatComparisons`.

use diffuse_math::simd::simd_compat::Float3;
use diffuse_math::utility::float_comparisons::FloatComparisons;

// "nearlyEqual compares scalars and vectors with tolerance"
#[test]
fn nearly_equal_compares_scalars_and_vectors() {
    assert!(FloatComparisons::nearly_equal_scalar_default(
        1.0,
        1.000_000_4
    ));
    assert!(!FloatComparisons::nearly_equal_scalar_default(1.0, 1.01));
    assert!(FloatComparisons::nearly_equal_default(
        Float3::new(1.0, 2.0, 3.0),
        Float3::new(1.000_000_4, 2.0, 2.999_999_8)
    ));
}

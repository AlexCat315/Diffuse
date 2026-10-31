//! `FloatComparisons` — tolerance-based float equality.

use crate::simd::simd_compat::Float3;

pub enum FloatComparisons {}

impl FloatComparisons {
    /// Swift's default tolerance is `0.000_001`.
    pub const DEFAULT_TOLERANCE: f32 = 0.000_001;

    #[inline]
    pub fn nearly_equal_scalar(lhs: f32, rhs: f32, tolerance: f32) -> bool {
        (lhs - rhs).abs() <= tolerance
    }

    #[inline]
    pub fn nearly_equal_scalar_default(lhs: f32, rhs: f32) -> bool {
        Self::nearly_equal_scalar(lhs, rhs, Self::DEFAULT_TOLERANCE)
    }

    #[inline]
    pub fn nearly_equal(lhs: Float3, rhs: Float3, tolerance: f32) -> bool {
        Self::nearly_equal_scalar(lhs.x, rhs.x, tolerance)
            && Self::nearly_equal_scalar(lhs.y, rhs.y, tolerance)
            && Self::nearly_equal_scalar(lhs.z, rhs.z, tolerance)
    }

    #[inline]
    pub fn nearly_equal_default(lhs: Float3, rhs: Float3) -> bool {
        Self::nearly_equal(lhs, rhs, Self::DEFAULT_TOLERANCE)
    }
}

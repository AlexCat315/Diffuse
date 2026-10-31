//! `Transform3D` — translation, rotation and scale.

use crate::simd::simd_compat::{
    Float3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, Quatf, simd_inverse,
};
use crate::transforms::matrix_transforms::MatrixTransforms;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Transform3D {
    pub translation: Float3,
    pub rotation: Quatf,
    pub scale: Float3,
}

impl Transform3D {
    #[inline]
    pub const fn new(translation: Float3, rotation: Quatf, scale: Float3) -> Self {
        Transform3D {
            translation,
            rotation,
            scale,
        }
    }

    /// The Swift default: zero translation, zero-angle rotation about +Y, unit scale.
    pub fn identity() -> Self {
        Transform3D {
            translation: Float3::ZERO,
            rotation: Quatf::from_angle_axis(0.0, Float3::new(0.0, 1.0, 0.0)),
            scale: Float3::ONE,
        }
    }

    pub fn matrix(&self) -> Float4x4 {
        MatrixTransforms::translation(self.translation)
            * Float4x4::from_quatf(self.rotation)
            * MatrixTransforms::scale(self.scale)
    }

    #[inline]
    pub fn inverse_matrix(&self) -> Float4x4 {
        simd_inverse(self.matrix())
    }

    pub fn transform_point(&self, point: Float3) -> Float3 {
        let result = self.matrix() * Float4::new(point.x, point.y, point.z, 1.0);
        Float3::new(result.x, result.y, result.z)
    }
}

impl Default for Transform3D {
    fn default() -> Self {
        Self::identity()
    }
}

const _: () = assert!(core::mem::size_of::<Transform3D>() == 48);

/// Identity matrix alias re-exported for call sites that used Swift's global.
pub const MATRIX_IDENTITY: Float4x4 = MATRIX_IDENTITY_FLOAT4X4;

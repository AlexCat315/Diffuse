//! `MatrixTransforms` — translation, scale and rotation matrices.

use crate::simd::simd_compat::{Float3, Float4, Float4x4, Quatf, simd_length_squared};

pub enum MatrixTransforms {}

impl MatrixTransforms {
    pub fn translation(value: Float3) -> Float4x4 {
        Float4x4::from_rows(&[
            Float4::new(1.0, 0.0, 0.0, value.x),
            Float4::new(0.0, 1.0, 0.0, value.y),
            Float4::new(0.0, 0.0, 1.0, value.z),
            Float4::new(0.0, 0.0, 0.0, 1.0),
        ])
    }

    pub fn scale(value: Float3) -> Float4x4 {
        Float4x4::from_rows(&[
            Float4::new(value.x, 0.0, 0.0, 0.0),
            Float4::new(0.0, value.y, 0.0, 0.0),
            Float4::new(0.0, 0.0, value.z, 0.0),
            Float4::new(0.0, 0.0, 0.0, 1.0),
        ])
    }

    pub fn rotation(axis: Float3, radians: f32) -> Float4x4 {
        let length_squared = simd_length_squared(axis);
        if length_squared <= f32::EPSILON {
            return crate::simd::simd_compat::MATRIX_IDENTITY_FLOAT4X4;
        }
        Float4x4::from_quatf(Quatf::from_angle_axis(
            radians,
            axis / length_squared.sqrt(),
        ))
    }
}

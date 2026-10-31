//! `CameraMatrices` — right-handed projection and view matrices for WebGPU's
//! 0...1 depth range.

use super::super::simd::simd_compat::{
    Float3, Float4, Float4x4, simd_cross, simd_dot, simd_length_squared,
};

pub enum CameraMatrices {}

impl CameraMatrices {
    /// Right-handed orthographic projection with WebGPU's 0...1 depth range.
    pub fn orthographic_rh_zo(height: f32, aspect: f32, near: f32, far: f32) -> Float4x4 {
        let safe_height = height.max(f32::EPSILON);
        let width = safe_height * aspect.max(f32::EPSILON);
        let depth = 1.0 / (near - far);
        Float4x4::from_rows(&[
            Float4::new(2.0 / width, 0.0, 0.0, 0.0),
            Float4::new(0.0, 2.0 / safe_height, 0.0, 0.0),
            Float4::new(0.0, 0.0, depth, near * depth),
            Float4::new(0.0, 0.0, 0.0, 1.0),
        ])
    }

    pub fn perspective_rh_zo(fov_y_radians: f32, aspect: f32, near: f32, far: f32) -> Float4x4 {
        let safe_aspect = aspect.max(f32::EPSILON);
        let f = 1.0 / (fov_y_radians * 0.5).tan();
        let nf = 1.0 / (near - far);
        Float4x4::from_rows(&[
            Float4::new(f / safe_aspect, 0.0, 0.0, 0.0),
            Float4::new(0.0, f, 0.0, 0.0),
            Float4::new(0.0, 0.0, far * nf, near * far * nf),
            Float4::new(0.0, 0.0, -1.0, 0.0),
        ])
    }

    pub fn look_at_rh(eye: Float3, target: Float3, up: Float3) -> Float4x4 {
        let forward = Self::normalize_or_fallback(target - eye, Float3::new(0.0, 0.0, -1.0));
        let side = Self::normalize_or_fallback(simd_cross(forward, up), Float3::new(1.0, 0.0, 0.0));
        let corrected_up = simd_cross(side, forward);
        Float4x4::from_rows(&[
            Float4::new(side.x, side.y, side.z, -simd_dot(side, eye)),
            Float4::new(
                corrected_up.x,
                corrected_up.y,
                corrected_up.z,
                -simd_dot(corrected_up, eye),
            ),
            Float4::new(-forward.x, -forward.y, -forward.z, simd_dot(forward, eye)),
            Float4::new(0.0, 0.0, 0.0, 1.0),
        ])
    }

    fn normalize_or_fallback(value: Float3, fallback: Float3) -> Float3 {
        let length_squared = simd_length_squared(value);
        if length_squared <= f32::EPSILON {
            return fallback;
        }
        value / length_squared.sqrt()
    }
}

//! Translation of Editor/Sources/EditorCore/Editing/EditorTransformSnapping.swift.

use std::f32::consts::PI;

use diffuse_math::simd::simd_compat::{
    Float3, Float3x3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, Quatf, simd_length,
};

use crate::editing::editor_gizmo_controller::GizmoMode;
use crate::state::editor_state::EditorState;

/// Quantizes only the active transform tool, preserving the other components.
pub struct EditorTransformSnapping;

impl EditorTransformSnapping {
    pub fn apply(matrix: Float4x4, mode: GizmoMode, state: &EditorState) -> Float4x4 {
        let mut result = matrix;
        match mode {
            GizmoMode::Translate => {
                if !state.snapping.translate_snap_enabled {
                    return result;
                }
                let step =
                    EditorState::sanitized_translate_snap_step(state.snapping.translate_snap_step);
                result.columns[3].x = Self::quantize(result.columns[3].x, step);
                result.columns[3].y = Self::quantize(result.columns[3].y, step);
                result.columns[3].z = Self::quantize(result.columns[3].z, step);
                result
            }
            GizmoMode::Rotate => {
                if !state.snapping.rotate_snap_enabled {
                    return result;
                }
                Self::snap_rotation(
                    result,
                    EditorState::sanitized_rotate_snap_step(
                        state.snapping.rotate_snap_step_degrees,
                    ),
                )
            }
            GizmoMode::Scale => {
                if !state.snapping.scale_snap_enabled {
                    return result;
                }
                Self::snap_scale(
                    result,
                    EditorState::sanitized_scale_snap_step(state.snapping.scale_snap_step),
                    0.001,
                )
            }
        }
    }

    fn snap_rotation(matrix: Float4x4, step_degrees: f32) -> Float4x4 {
        let (translation, rotation, scale) = Self::decompose_trs(&matrix);
        let euler = Self::quaternion_to_euler_xyz(rotation);
        let step = step_degrees * (PI / 180.0);
        let snapped_euler = Float3::new(
            Self::quantize(euler.x, step),
            Self::quantize(euler.y, step),
            Self::quantize(euler.z, step),
        );
        let snapped_q = Self::euler_xyz_to_quaternion(snapped_euler);
        Self::compose_trs(translation, snapped_q, scale)
    }

    fn snap_scale(matrix: Float4x4, step: f32, min_scale: f32) -> Float4x4 {
        let (translation, rotation, scale) = Self::decompose_trs(&matrix);
        let snapped = Float3::new(
            Self::quantize(scale.x, step).max(min_scale),
            Self::quantize(scale.y, step).max(min_scale),
            Self::quantize(scale.z, step).max(min_scale),
        );
        Self::compose_trs(translation, rotation, snapped)
    }

    fn quantize(value: f32, step: f32) -> f32 {
        if step <= 1e-6 {
            return value;
        }
        (value / step).round() * step
    }

    fn decompose_trs(matrix: &Float4x4) -> (Float3, Quatf, Float3) {
        let t = Float3::new(
            matrix.columns[3].x,
            matrix.columns[3].y,
            matrix.columns[3].z,
        );
        let c0 = Float3::new(
            matrix.columns[0].x,
            matrix.columns[0].y,
            matrix.columns[0].z,
        );
        let c1 = Float3::new(
            matrix.columns[1].x,
            matrix.columns[1].y,
            matrix.columns[1].z,
        );
        let c2 = Float3::new(
            matrix.columns[2].x,
            matrix.columns[2].y,
            matrix.columns[2].z,
        );
        let sx = simd_length(c0).max(1e-8);
        let sy = simd_length(c1).max(1e-8);
        let sz = simd_length(c2).max(1e-8);
        let r0 = c0 / sx;
        let r1 = c1 / sy;
        let r2 = c2 / sz;
        let rot_m = Float3x3::new_with_columns(r0, r1, r2);
        (t, Quatf::from_float3x3(rot_m), Float3::new(sx, sy, sz))
    }

    fn compose_trs(translation: Float3, rotation: Quatf, scale: Float3) -> Float4x4 {
        let rm = Float3x3::from_quatf(rotation);
        let mut out = Float4x4::from_columns(MATRIX_IDENTITY_FLOAT4X4.columns);
        let c0 = rm.columns[0] * scale.x;
        let c1 = rm.columns[1] * scale.y;
        let c2 = rm.columns[2] * scale.z;
        out.columns[0] = Float4::new(c0.x, c0.y, c0.z, 0.0);
        out.columns[1] = Float4::new(c1.x, c1.y, c1.z, 0.0);
        out.columns[2] = Float4::new(c2.x, c2.y, c2.z, 0.0);
        out.columns[3] = Float4::new(translation.x, translation.y, translation.z, 1.0);
        out
    }

    fn quaternion_to_euler_xyz(q: Quatf) -> Float3 {
        let imag = q.imag();
        let x = imag.x;
        let y = imag.y;
        let z = imag.z;
        let w = q.real();

        let sinr_cosp = 2.0 * (w * x + y * z);
        let cosr_cosp = 1.0 - 2.0 * (x * x + y * y);
        let roll = sinr_cosp.atan2(cosr_cosp);

        let sinp = 2.0 * (w * y - z * x);
        let pitch = if sinp.abs() >= 1.0 {
            (PI * 0.5).copysign(sinp)
        } else {
            sinp.asin()
        };

        let siny_cosp = 2.0 * (w * z + x * y);
        let cosy_cosp = 1.0 - 2.0 * (y * y + z * z);
        let yaw = siny_cosp.atan2(cosy_cosp);

        Float3::new(roll, pitch, yaw)
    }

    fn euler_xyz_to_quaternion(euler: Float3) -> Quatf {
        let qx = Quatf::from_angle_axis(euler.x, Float3::new(1.0, 0.0, 0.0));
        let qy = Quatf::from_angle_axis(euler.y, Float3::new(0.0, 1.0, 0.0));
        let qz = Quatf::from_angle_axis(euler.z, Float3::new(0.0, 0.0, 1.0));
        qz * qy * qx
    }
}

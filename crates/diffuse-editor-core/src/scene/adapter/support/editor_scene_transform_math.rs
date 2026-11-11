//! `Editor/Sources/EditorCore/Scene/Adapter/Support/EditorSceneTransformMath.swift`.

use diffuse_math::simd::simd_compat::{
    Float3, Float3x3, Float4, Float4x4, MATRIX_IDENTITY_FLOAT4X4, simd_length,
};

/// Decomposes a 4x4 local matrix into a pure rotation 3x3 and a per-axis scale
/// vector. A matrix with shear would only approximate the scale by column
/// lengths; the editor never authors shear.
pub fn decompose_rotation_scale(m: &Float4x4) -> (Float3x3, Float3) {
    let c0 = Float3::new(m.columns[0].x, m.columns[0].y, m.columns[0].z);
    let c1 = Float3::new(m.columns[1].x, m.columns[1].y, m.columns[1].z);
    let c2 = Float3::new(m.columns[2].x, m.columns[2].y, m.columns[2].z);
    let sx = simd_length(c0);
    let sy = simd_length(c1);
    let sz = simd_length(c2);
    let r0 = if sx > 1e-5 {
        c0 / sx
    } else {
        Float3::new(1.0, 0.0, 0.0)
    };
    let r1 = if sy > 1e-5 {
        c1 / sy
    } else {
        Float3::new(0.0, 1.0, 0.0)
    };
    let r2 = if sz > 1e-5 {
        c2 / sz
    } else {
        Float3::new(0.0, 0.0, 1.0)
    };
    (
        Float3x3::new_with_columns(r0, r1, r2),
        Float3::new(sx, sy, sz),
    )
}

pub fn compose_matrix(translation: Float3, rotation: &Float3x3, scale: Float3) -> Float4x4 {
    let c0 = rotation.columns[0] * scale.x;
    let c1 = rotation.columns[1] * scale.y;
    let c2 = rotation.columns[2] * scale.z;
    let mut m = Float4x4::from_columns(MATRIX_IDENTITY_FLOAT4X4.columns);
    m.columns[0] = Float4::new(c0.x, c0.y, c0.z, 0.0);
    m.columns[1] = Float4::new(c1.x, c1.y, c1.z, 0.0);
    m.columns[2] = Float4::new(c2.x, c2.y, c2.z, 0.0);
    m.columns[3] = Float4::new(translation.x, translation.y, translation.z, 1.0);
    m
}

/// Extracts Euler XYZ from a 3x3 rotation (intrinsic order: `R = Rx * Ry * Rz`).
/// Cove's matrices are column-major: `m.columns[c][r]` is the mathematical
/// `R[r][c]`.
pub fn euler_xyz_from_matrix(m: &Float3x3) -> Float3 {
    let r02 = m.columns[2].x;
    let r12 = m.columns[2].y;
    let r22 = m.columns[2].z;
    let r00 = m.columns[0].x;
    let r01 = m.columns[1].x;

    let sy = r02.clamp(-1.0, 1.0);
    let y = sy.asin();
    let cy = y.cos();
    let (x, z) = if cy.abs() > 1e-4 {
        ((-r12).atan2(r22), (-r01).atan2(r00))
    } else {
        // Gimbal lock: fix z = 0 and solve x.
        (m.columns[0].y.atan2(m.columns[1].y), 0.0)
    };
    Float3::new(x, y, z)
}

/// Composes the 3x3 rotation from Euler XYZ (radians, intrinsic):
/// `R = Rx * Ry * Rz`.
pub fn matrix_from_euler_xyz(e: Float3) -> Float3x3 {
    let (cx, sx) = (e.x.cos(), e.x.sin());
    let (cy, sy) = (e.y.cos(), e.y.sin());
    let (cz, sz) = (e.z.cos(), e.z.sin());

    let r00 = cy * cz;
    let r01 = -cy * sz;
    let r02 = sy;
    let r10 = sx * sy * cz + cx * sz;
    let r11 = -sx * sy * sz + cx * cz;
    let r12 = -sx * cy;
    let r20 = -cx * sy * cz + sx * sz;
    let r21 = cx * sy * sz + sx * cz;
    let r22 = cx * cy;

    // Column-major: columns[c][r] = R[r][c].
    Float3x3::new_with_columns(
        Float3::new(r00, r10, r20),
        Float3::new(r01, r11, r21),
        Float3::new(r02, r12, r22),
    )
}

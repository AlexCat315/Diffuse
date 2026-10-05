import Foundation
import SIMDCompat


// MARK: - Transform decompose / compose

/// 把 4x4 本地矩阵分解成纯旋转 3x3 + per-axis 缩放向量。
/// 假设矩阵不含切变；如果有切变，缩放只取列长度近似。
func decomposeRotationScale(_ m: simd_float4x4) -> (simd_float3x3, SIMD3<Float>) {
    let c0 = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
    let c1 = SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z)
    let c2 = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
    let sx = simd_length(c0)
    let sy = simd_length(c1)
    let sz = simd_length(c2)
    let r0 = sx > 1e-5 ? c0 / sx : SIMD3<Float>(1, 0, 0)
    let r1 = sy > 1e-5 ? c1 / sy : SIMD3<Float>(0, 1, 0)
    let r2 = sz > 1e-5 ? c2 / sz : SIMD3<Float>(0, 0, 1)
    return (simd_float3x3(columns: (r0, r1, r2)), SIMD3<Float>(sx, sy, sz))
}

func composeMatrix(translation: SIMD3<Float>,
                           rotation: simd_float3x3,
                           scale: SIMD3<Float>) -> simd_float4x4 {
    let c0 = rotation.columns.0 * scale.x
    let c1 = rotation.columns.1 * scale.y
    let c2 = rotation.columns.2 * scale.z
    var m = matrix_identity_float4x4
    m.columns.0 = SIMD4<Float>(c0, 0)
    m.columns.1 = SIMD4<Float>(c1, 0)
    m.columns.2 = SIMD4<Float>(c2, 0)
    m.columns.3 = SIMD4<Float>(translation, 1)
    return m
}

/// 从 3x3 旋转矩阵提取 Euler XYZ（intrinsic 顺序：R = Rx * Ry * Rz）。
/// 这里 simd 是 column-major：m[c][r] 等价数学约定 R[r][c]。
func eulerXYZFromMatrix(_ m: simd_float3x3) -> SIMD3<Float> {
    // R[r][c] = m.columns[c][r]
    let r02 = m.columns.2.x // R[0][2]
    let r12 = m.columns.2.y // R[1][2]
    let r22 = m.columns.2.z // R[2][2]
    let r00 = m.columns.0.x // R[0][0]
    let r01 = m.columns.1.x // R[0][1]

    let sy = max(-1, min(1, r02))
    let y = asinf(sy)
    let cy = cosf(y)
    let x: Float
    let z: Float
    if abs(cy) > 1e-4 {
        x = atan2f(-r12, r22)
        z = atan2f(-r01, r00)
    } else {
        // gimbal lock: 设 z = 0 解 x。
        x = atan2f(m.columns.0.y, m.columns.1.y) // atan2(R[1][0], R[1][1])
        z = 0
    }
    return SIMD3<Float>(x, y, z)
}

/// 从 Euler XYZ（弧度，intrinsic）合成 3x3 旋转矩阵：R = Rx * Ry * Rz。
func matrixFromEulerXYZ(_ e: SIMD3<Float>) -> simd_float3x3 {
    let cx = cosf(e.x), sx = sinf(e.x)
    let cy = cosf(e.y), sy = sinf(e.y)
    let cz = cosf(e.z), sz = sinf(e.z)

    // R = Rx * Ry * Rz
    // 逐项展开
    let r00 = cy * cz
    let r01 = -cy * sz
    let r02 = sy
    let r10 = sx * sy * cz + cx * sz
    let r11 = -sx * sy * sz + cx * cz
    let r12 = -sx * cy
    let r20 = -cx * sy * cz + sx * sz
    let r21 = cx * sy * sz + sx * cz
    let r22 = cx * cy

    // simd column-major: columns[c][r] = R[r][c]
    return simd_float3x3(columns: (
        SIMD3<Float>(r00, r10, r20),
        SIMD3<Float>(r01, r11, r21),
        SIMD3<Float>(r02, r12, r22)
    ))
}

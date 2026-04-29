import simd

public enum MatrixTransforms {
    public static func translation(_ value: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(rows: [
            SIMD4<Float>(1, 0, 0, value.x),
            SIMD4<Float>(0, 1, 0, value.y),
            SIMD4<Float>(0, 0, 1, value.z),
            SIMD4<Float>(0, 0, 0, 1),
        ])
    }

    public static func scale(_ value: SIMD3<Float>) -> simd_float4x4 {
        simd_float4x4(rows: [
            SIMD4<Float>(value.x, 0, 0, 0),
            SIMD4<Float>(0, value.y, 0, 0),
            SIMD4<Float>(0, 0, value.z, 0),
            SIMD4<Float>(0, 0, 0, 1),
        ])
    }

    public static func rotation(axis: SIMD3<Float>, radians: Float) -> simd_float4x4 {
        let lengthSquared = simd_length_squared(axis)
        guard lengthSquared > Float.ulpOfOne else { return matrix_identity_float4x4 }
        return simd_float4x4(simd_quatf(angle: radians, axis: axis / sqrt(lengthSquared)))
    }
}

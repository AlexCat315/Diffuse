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
}

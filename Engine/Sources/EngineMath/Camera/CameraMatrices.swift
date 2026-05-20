import SIMDCompat

public enum CameraMatrices {
    public static func perspectiveRH_ZO(fovYRadians: Float,
                                        aspect: Float,
                                        near: Float,
                                        far: Float) -> simd_float4x4 {
        let safeAspect = max(aspect, Float.ulpOfOne)
        let f = 1.0 / tan(fovYRadians * 0.5)
        let nf = 1.0 / (near - far)
        return simd_float4x4(rows: [
            SIMD4<Float>(f / safeAspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, far * nf, near * far * nf),
            SIMD4<Float>(0, 0, -1, 0),
        ])
    }

    public static func lookAtRH(eye: SIMD3<Float>,
                                target: SIMD3<Float>,
                                up: SIMD3<Float>) -> simd_float4x4 {
        let forward = normalizeOrFallback(target - eye, fallback: SIMD3<Float>(0, 0, -1))
        let side = normalizeOrFallback(simd_cross(forward, up), fallback: SIMD3<Float>(1, 0, 0))
        let correctedUp = simd_cross(side, forward)
        return simd_float4x4(rows: [
            SIMD4<Float>(side.x, side.y, side.z, -simd_dot(side, eye)),
            SIMD4<Float>(correctedUp.x, correctedUp.y, correctedUp.z, -simd_dot(correctedUp, eye)),
            SIMD4<Float>(-forward.x, -forward.y, -forward.z, simd_dot(forward, eye)),
            SIMD4<Float>(0, 0, 0, 1),
        ])
    }

    private static func normalizeOrFallback(_ value: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let lengthSquared = simd_length_squared(value)
        guard lengthSquared > Float.ulpOfOne else { return fallback }
        return value / sqrt(lengthSquared)
    }
}

import EngineKernel
import SIMDCompat

extension ParticleEmitter {
    mutating func nextUnit() -> Float {
        // SplitMix64 → [0, 1)
        runtime.rngState &+= 0x9E3779B97F4A7C15
        var z = runtime.rngState
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Float(z >> 40) * (1.0 / 16_777_216.0)
    }

    mutating func nextSigned() -> Float { nextUnit() * 2 - 1 }

    mutating func spawnOffset() -> SIMD3<Float> {
        switch emissionShape {
        case .sphere:
            return randomInSphere() * spawnRadius
        case .box:
            return randomInBox()
        case .cone:
            return randomInCone()
        }
    }

    private mutating func randomInSphere() -> SIMD3<Float> {
        guard spawnRadius > 0 else { return .zero }
        // Rejection sampling keeps the distribution uniform inside the unit sphere.
        for _ in 0..<8 {
            let v = SIMD3<Float>(nextSigned(), nextSigned(), nextSigned())
            if simd_length_squared(v) <= 1 { return v }
        }
        return .zero
    }

    private mutating func randomInBox() -> SIMD3<Float> {
        SIMD3<Float>(
            nextSigned() * boxHalfExtents.x,
            nextSigned() * boxHalfExtents.y,
            nextSigned() * boxHalfExtents.z
        )
    }

    private mutating func randomInCone() -> SIMD3<Float> {
        guard coneRadius > 0, coneHeight > 0 else { return .zero }
        let axis = normalizedOrDefault(startVelocity, SIMD3<Float>(0, 1, 0))
        let basis = coneBasis(axis: axis)
        let height = coneHeight * cbrt(nextUnit())
        let diskRadius = coneRadius * (height / coneHeight) * sqrt(nextUnit())
        let angle = nextUnit() * 2 * Float.pi
        return axis * height
            + basis.tangent * (cos(angle) * diskRadius)
            + basis.bitangent * (sin(angle) * diskRadius)
    }

    func normalizedOrDefault(_ v: SIMD3<Float>, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        let len = simd_length(v)
        guard len > 0.0001 else { return fallback }
        return v / len
    }

    private func coneBasis(axis: SIMD3<Float>) -> (tangent: SIMD3<Float>, bitangent: SIMD3<Float>) {
        let reference = abs(axis.y) < 0.99 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let tangent = normalizedOrDefault(simd_cross(reference, axis), SIMD3<Float>(1, 0, 0))
        let bitangent = normalizedOrDefault(simd_cross(axis, tangent), SIMD3<Float>(0, 0, 1))
        return (tangent, bitangent)
    }
}

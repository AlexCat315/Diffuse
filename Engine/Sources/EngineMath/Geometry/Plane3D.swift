import SIMDCompat

public struct Plane3D: Sendable, Equatable {
    public var normal: SIMD3<Float>
    public var distance: Float

    public init(normal: SIMD3<Float>, distance: Float, normalize: Bool = true) {
        if normalize {
            let length = simd_length(normal)
            if length > Float.ulpOfOne {
                self.normal = normal / length
                self.distance = distance / length
                return
            }
        }
        self.normal = normal
        self.distance = distance
    }

    public init(normal: SIMD3<Float>, point: SIMD3<Float>) {
        let length = simd_length(normal)
        let safeNormal = length > Float.ulpOfOne ? normal / length : SIMD3<Float>(0, 1, 0)
        self.normal = safeNormal
        self.distance = -simd_dot(safeNormal, point)
    }

    public func signedDistance(to point: SIMD3<Float>) -> Float {
        simd_dot(normal, point) + distance
    }

    public func maxSignedDistance(to bounds: Bounds3D) -> Float {
        guard !bounds.isEmpty else { return -.infinity }
        let point = SIMD3<Float>(
            normal.x >= 0 ? bounds.max.x : bounds.min.x,
            normal.y >= 0 ? bounds.max.y : bounds.min.y,
            normal.z >= 0 ? bounds.max.z : bounds.min.z
        )
        return signedDistance(to: point)
    }

    public func minSignedDistance(to bounds: Bounds3D) -> Float {
        guard !bounds.isEmpty else { return .infinity }
        let point = SIMD3<Float>(
            normal.x >= 0 ? bounds.min.x : bounds.max.x,
            normal.y >= 0 ? bounds.min.y : bounds.max.y,
            normal.z >= 0 ? bounds.min.z : bounds.max.z
        )
        return signedDistance(to: point)
    }
}

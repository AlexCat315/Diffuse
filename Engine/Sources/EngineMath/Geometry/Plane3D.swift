import simd

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
}

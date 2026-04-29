import simd

public struct Ray3D: Sendable, Equatable {
    public var origin: SIMD3<Float>
    public var direction: SIMD3<Float>

    public init(origin: SIMD3<Float>, direction: SIMD3<Float>, normalizeDirection: Bool = true) {
        self.origin = origin
        if normalizeDirection {
            let lengthSquared = simd_length_squared(direction)
            self.direction = lengthSquared > Float.ulpOfOne
                ? direction / sqrt(lengthSquared)
                : SIMD3<Float>(0, 0, -1)
        } else {
            self.direction = direction
        }
    }

    public func point(at distance: Float) -> SIMD3<Float> {
        origin + direction * distance
    }
}

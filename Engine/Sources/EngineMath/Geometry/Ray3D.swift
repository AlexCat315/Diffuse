import SIMDCompat

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

    public func distance(to bounds: Bounds3D) -> Float? {
        guard !bounds.isEmpty else { return nil }
        var tMin: Float = 0
        var tMax: Float = .infinity
        for axis in 0..<3 {
            let originValue = origin[axis]
            let directionValue = direction[axis]
            if abs(directionValue) <= Float.ulpOfOne {
                if originValue < bounds.min[axis] || originValue > bounds.max[axis] {
                    return nil
                }
                continue
            }
            let inverse = 1 / directionValue
            var near = (bounds.min[axis] - originValue) * inverse
            var far = (bounds.max[axis] - originValue) * inverse
            if near > far { swap(&near, &far) }
            tMin = max(tMin, near)
            tMax = min(tMax, far)
            if tMin > tMax { return nil }
        }
        return tMin
    }
}

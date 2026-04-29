import simd

public struct Bounds3D: Sendable, Equatable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    public var center: SIMD3<Float> {
        (min + max) * 0.5
    }

    public var extent: SIMD3<Float> {
        max - min
    }

    public var halfExtent: SIMD3<Float> {
        extent * 0.5
    }
}

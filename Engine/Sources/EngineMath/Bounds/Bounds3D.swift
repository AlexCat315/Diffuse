import simd

public struct Bounds3D: Sendable, Equatable {
    public var min: SIMD3<Float>
    public var max: SIMD3<Float>

    public init(min: SIMD3<Float>, max: SIMD3<Float>) {
        self.min = min
        self.max = max
    }

    public static let empty = Bounds3D(
        min: SIMD3<Float>(repeating: .infinity),
        max: SIMD3<Float>(repeating: -.infinity)
    )

    public init(points: some Sequence<SIMD3<Float>>) {
        var bounds = Bounds3D.empty
        for point in points {
            bounds.include(point)
        }
        self = bounds.isEmpty ? Bounds3D(min: .zero, max: .zero) : bounds
    }

    public var isEmpty: Bool {
        min.x > max.x || min.y > max.y || min.z > max.z
    }

    public var center: SIMD3<Float> {
        guard !isEmpty else { return .zero }
        return (min + max) * 0.5
    }

    public var extent: SIMD3<Float> {
        guard !isEmpty else { return .zero }
        return max - min
    }

    public var halfExtent: SIMD3<Float> {
        extent * 0.5
    }

    public mutating func include(_ point: SIMD3<Float>) {
        min = simd_min(min, point)
        max = simd_max(max, point)
    }

    public func contains(_ point: SIMD3<Float>) -> Bool {
        guard !isEmpty else { return false }
        return point.x >= min.x && point.x <= max.x
            && point.y >= min.y && point.y <= max.y
            && point.z >= min.z && point.z <= max.z
    }

    public func closestPoint(to point: SIMD3<Float>) -> SIMD3<Float> {
        guard !isEmpty else { return .zero }
        return simd_min(simd_max(point, min), max)
    }
}

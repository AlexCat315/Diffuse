import simd

public struct Frustum3D: Sendable, Equatable {
    public var planes: [Plane3D]

    public init(planes: [Plane3D]) {
        self.planes = planes
    }

    public init(viewProjection: simd_float4x4) {
        let r0 = Self.row(0, of: viewProjection)
        let r1 = Self.row(1, of: viewProjection)
        let r2 = Self.row(2, of: viewProjection)
        let r3 = Self.row(3, of: viewProjection)
        self.planes = [
            Self.plane(r3 + r0),
            Self.plane(r3 - r0),
            Self.plane(r3 + r1),
            Self.plane(r3 - r1),
            Self.plane(r2),
            Self.plane(r3 - r2),
        ]
    }

    public func containsSphere(center: SIMD3<Float>, radius: Float) -> Bool {
        for plane in planes where plane.signedDistance(to: center) < -radius {
            return false
        }
        return true
    }

    public func intersects(_ bounds: Bounds3D) -> Bool {
        guard !bounds.isEmpty else { return false }
        for plane in planes where plane.maxSignedDistance(to: bounds) < 0 {
            return false
        }
        return true
    }

    private static func plane(_ value: SIMD4<Float>) -> Plane3D {
        Plane3D(normal: SIMD3<Float>(value.x, value.y, value.z), distance: value.w)
    }

    private static func row(_ index: Int, of matrix: simd_float4x4) -> SIMD4<Float> {
        SIMD4<Float>(
            matrix.columns.0[index],
            matrix.columns.1[index],
            matrix.columns.2[index],
            matrix.columns.3[index]
        )
    }
}

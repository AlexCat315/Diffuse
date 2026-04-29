import EngineMath
import simd
import Testing

@Suite("Bounds3D")
struct Bounds3DTests {
    @Test("bounds expose center and extents")
    func boundsExposeCenterAndExtents() {
        let bounds = Bounds3D(
            min: SIMD3<Float>(-1, 2, 4),
            max: SIMD3<Float>(3, 6, 10)
        )

        #expect(bounds.center == SIMD3<Float>(1, 4, 7))
        #expect(bounds.extent == SIMD3<Float>(4, 4, 6))
        #expect(bounds.halfExtent == SIMD3<Float>(2, 2, 3))
    }

    @Test("bounds can be built from point sequences")
    func boundsCanBeBuiltFromPointSequences() {
        let bounds = Bounds3D(points: [
            SIMD3<Float>(2, -1, 4),
            SIMD3<Float>(-3, 5, 1),
            SIMD3<Float>(0, 2, 9),
        ])

        #expect(!bounds.isEmpty)
        #expect(bounds.min == SIMD3<Float>(-3, -1, 1))
        #expect(bounds.max == SIMD3<Float>(2, 5, 9))
        #expect(Bounds3D.empty.isEmpty)
    }

    @Test("bounds contain points and clamp to closest point")
    func boundsContainPointsAndClamp() {
        let bounds = Bounds3D(
            min: SIMD3<Float>(-1, 0, 2),
            max: SIMD3<Float>(3, 4, 6)
        )

        #expect(bounds.contains(SIMD3<Float>(1, 2, 3)))
        #expect(!bounds.contains(SIMD3<Float>(4, 2, 3)))
        #expect(bounds.closestPoint(to: SIMD3<Float>(6, -2, 4)) == SIMD3<Float>(3, 0, 4))
        #expect(!Bounds3D.empty.contains(.zero))
    }
}

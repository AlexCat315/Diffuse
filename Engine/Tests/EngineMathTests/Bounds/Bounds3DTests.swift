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

    @Test("bounds support union and intersection")
    func boundsSupportUnionAndIntersection() throws {
        let a = Bounds3D(min: SIMD3<Float>(0, 0, 0), max: SIMD3<Float>(3, 3, 3))
        let b = Bounds3D(min: SIMD3<Float>(2, -1, 1), max: SIMD3<Float>(4, 2, 5))
        let union = a.union(b)
        let intersection = try #require(a.intersection(b))

        #expect(union.min == SIMD3<Float>(0, -1, 0))
        #expect(union.max == SIMD3<Float>(4, 3, 5))
        #expect(intersection.min == SIMD3<Float>(2, 0, 1))
        #expect(intersection.max == SIMD3<Float>(3, 2, 3))
        #expect(a.intersects(b))
        #expect(!a.intersects(Bounds3D(min: SIMD3<Float>(5, 5, 5), max: SIMD3<Float>(6, 6, 6))))
    }
}

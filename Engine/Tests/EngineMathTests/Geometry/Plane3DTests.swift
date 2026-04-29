import EngineMath
import simd
import Testing

@Suite("Plane3D")
struct Plane3DTests {
    @Test("plane computes signed point distances")
    func planeComputesSignedPointDistances() {
        let plane = Plane3D(normal: SIMD3<Float>(0, 2, 0), point: SIMD3<Float>(0, 3, 0))

        #expect(plane.normal == SIMD3<Float>(0, 1, 0))
        #expect(plane.signedDistance(to: SIMD3<Float>(0, 5, 0)) == 2)
        #expect(plane.signedDistance(to: SIMD3<Float>(0, 1, 0)) == -2)
    }

    @Test("plane computes conservative bounds distances")
    func planeComputesBoundsDistances() {
        let plane = Plane3D(normal: SIMD3<Float>(1, 0, 0), distance: -2)
        let bounds = Bounds3D(min: SIMD3<Float>(1, -1, -1), max: SIMD3<Float>(4, 1, 1))

        #expect(plane.minSignedDistance(to: bounds) == -1)
        #expect(plane.maxSignedDistance(to: bounds) == 2)
    }
}

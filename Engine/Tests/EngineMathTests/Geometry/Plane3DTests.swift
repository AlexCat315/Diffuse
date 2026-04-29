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
}

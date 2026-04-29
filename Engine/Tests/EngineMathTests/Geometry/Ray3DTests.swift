import EngineMath
import simd
import Testing

@Suite("Ray3D")
struct Ray3DTests {
    @Test("ray normalizes direction and samples points")
    func rayNormalizesDirectionAndSamplesPoints() {
        let ray = Ray3D(origin: SIMD3<Float>(1, 2, 3), direction: SIMD3<Float>(0, 0, -5))

        #expect(ray.direction == SIMD3<Float>(0, 0, -1))
        #expect(ray.point(at: 4) == SIMD3<Float>(1, 2, -1))
    }
}

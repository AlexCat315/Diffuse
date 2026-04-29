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

    @Test("ray intersects bounds with nearest positive distance")
    func rayIntersectsBounds() throws {
        let bounds = Bounds3D(min: SIMD3<Float>(-1, -1, -1), max: SIMD3<Float>(1, 1, 1))
        let ray = Ray3D(origin: SIMD3<Float>(0, 0, 5), direction: SIMD3<Float>(0, 0, -1))
        let miss = Ray3D(origin: SIMD3<Float>(3, 0, 5), direction: SIMD3<Float>(0, 0, -1))

        #expect(ray.distance(to: bounds) == 4)
        #expect(miss.distance(to: bounds) == nil)
        #expect(Ray3D(origin: .zero, direction: SIMD3<Float>(1, 0, 0)).distance(to: bounds) == 0)
    }
}

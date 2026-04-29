import EngineMath
import simd
import Testing

@Suite("MatrixTransforms")
struct MatrixTransformsTests {
    @Test("translation and scale transform points")
    func translationAndScaleTransformPoints() {
        let point = SIMD4<Float>(1, 2, 3, 1)
        let translated = MatrixTransforms.translation(SIMD3<Float>(4, -2, 1)) * point
        let scaled = MatrixTransforms.scale(SIMD3<Float>(2, 3, 4)) * point

        #expect(translated == SIMD4<Float>(5, 0, 4, 1))
        #expect(scaled == SIMD4<Float>(2, 6, 12, 1))
    }
}

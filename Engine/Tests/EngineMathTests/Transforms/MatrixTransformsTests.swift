import EngineMath
import SIMDCompat
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

    @Test("axis rotations transform directions")
    func axisRotationsTransformDirections() {
        let rotated = MatrixTransforms.rotation(axis: SIMD3<Float>(0, 0, 1), radians: .pi / 2)
            * SIMD4<Float>(1, 0, 0, 0)

        #expect(FloatComparisons.nearlyEqual(SIMD3<Float>(rotated.x, rotated.y, rotated.z),
                                            SIMD3<Float>(0, 1, 0)))
    }
}

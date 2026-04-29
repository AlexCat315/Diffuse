import EngineMath
import simd
import Testing

@Suite("Transform3D")
struct Transform3DTests {
    @Test("transform composes translation rotation and scale into a matrix")
    func transformComposesMatrix() {
        let transform = Transform3D(
            translation: SIMD3<Float>(3, 0, 0),
            rotation: simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 0, 1)),
            scale: SIMD3<Float>(2, 2, 2)
        )
        let point = transform.matrix * SIMD4<Float>(1, 0, 0, 1)

        #expect(FloatComparisons.nearlyEqual(SIMD3<Float>(point.x, point.y, point.z),
                                            SIMD3<Float>(3, 2, 0)))
    }
}

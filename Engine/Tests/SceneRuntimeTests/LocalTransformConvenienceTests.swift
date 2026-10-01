import SceneRuntime
import SIMDCompat
import Testing

@Suite("Gameplay transform construction")
struct LocalTransformConvenienceTests {
    @Test("translation edits preserve rotated nonuniform scale")
    func editsTranslation() {
        let rotation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        var transform = LocalTransform(translation: SIMD3(1, 2, 3), rotation: rotation, scale: SIMD3(2, 3, 4))
        let basis = transform.matrix
        let point = transform.matrix * SIMD4<Float>(1, 0, 0, 1)
        #expect(abs(point.x - 1) < 0.0001)
        #expect(abs(point.z - 1) < 0.0001)
        transform.translation = SIMD3(9, 8, 7)
        #expect(transform.matrix.columns.0 == basis.columns.0)
        #expect(transform.matrix.columns.1 == basis.columns.1)
        #expect(transform.matrix.columns.2 == basis.columns.2)
        #expect(transform.translation == SIMD3(9, 8, 7))
    }
}

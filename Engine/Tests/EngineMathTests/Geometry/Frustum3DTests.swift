import EngineMath
import simd
import Testing

@Suite("Frustum3D")
struct Frustum3DTests {
    @Test("frustum tests spheres and bounds")
    func frustumTestsSpheresAndBounds() {
        let frustum = Frustum3D(viewProjection: matrix_identity_float4x4)

        #expect(frustum.containsSphere(center: SIMD3<Float>(0, 0, 0.5), radius: 0.25))
        #expect(!frustum.containsSphere(center: SIMD3<Float>(3, 0, 0.5), radius: 0.25))
        #expect(frustum.intersects(Bounds3D(min: SIMD3<Float>(-0.5, -0.5, 0.25),
                                           max: SIMD3<Float>(0.5, 0.5, 0.75))))
        #expect(!frustum.intersects(Bounds3D(min: SIMD3<Float>(2, 2, 2),
                                            max: SIMD3<Float>(3, 3, 3))))
    }
}

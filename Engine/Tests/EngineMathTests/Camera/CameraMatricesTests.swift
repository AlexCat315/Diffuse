import EngineMath
import simd
import Testing

@Suite("CameraMatrices")
struct CameraMatricesTests {
    @Test("perspectiveRH_ZO matches renderer projection convention")
    func perspectiveMatchesRendererConvention() {
        let projection = CameraMatrices.perspectiveRH_ZO(
            fovYRadians: .pi / 2,
            aspect: 1,
            near: 0.1,
            far: 100
        )

        #expect(abs(projection.columns.0.x - 1) < 0.000_001)
        #expect(abs(projection.columns.1.y - 1) < 0.000_001)
        #expect(abs(projection.columns.2.z - (-1.001_001)) < 0.000_001)
        #expect(abs(projection.columns.3.z - (-0.100_100_1)) < 0.000_001)
        #expect(projection.columns.2.w == -1)
    }

    @Test("lookAtRH places the camera at the origin in view space")
    func lookAtPlacesEyeAtOrigin() {
        let eye = SIMD3<Float>(0, 3, 8)
        let view = CameraMatrices.lookAtRH(
            eye: eye,
            target: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0)
        )
        let transformedEye = view * SIMD4<Float>(eye.x, eye.y, eye.z, 1)

        #expect(abs(transformedEye.x) < 0.000_001)
        #expect(abs(transformedEye.y) < 0.000_001)
        #expect(abs(transformedEye.z) < 0.000_001)
        #expect(transformedEye.w == 1)
    }
}

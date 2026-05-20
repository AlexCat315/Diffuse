@testable import RenderBackend
import SceneRuntime
import SIMDCompat
import Testing

@Suite("RenderCameraMatrices")
struct RenderCameraMatricesTests {
    @Test("makes projection view and combined matrices")
    func makesProjectionViewAndCombinedMatrices() {
        let scene = RenderScene(
            camera: RenderCamera(
                eye: SIMD3<Float>(0, 0, 5),
                target: .zero,
                up: SIMD3<Float>(0, 1, 0),
                fovYRadians: .pi / 2,
                near: 0.1,
                far: 100
            ),
            instances: []
        )

        let matrices = RenderCameraMatrices.make(
            scene: scene,
            drawableSize: RenderDrawableSize(width: 100, height: 50)
        )

        #expect(abs(matrices.projection.columns.0.x - 0.5) < 0.000_001)
        #expect(matrices.viewProjection == matrices.projection * matrices.view)
    }
}

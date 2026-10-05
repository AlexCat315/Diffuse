@testable import RenderBackend
import SceneRuntime
import RHIWGPU
import SIMDCompat
import Testing

@Suite("RenderCameraMatrices")
struct RenderCameraMatricesTests {
    @Test("orthographic shadow cascades follow visible height and carry parallel shading with shadows off")
    func orthographicShadowFrustum() {
        let renderer = WGPURenderer(backend: WGPUBackend(config: .init()))
        var scene = RenderScene(camera: RenderCamera(eye: SIMD3<Float>(0, 0, 8), target: .zero,
            near: 0.1, far: 30, projection: .orthographic, orthographicHeight: 6), instances: [],
            lights: [RenderLight(type: .directional, direction: SIMD3<Float>(-1, -2, -1))])
        let size = RenderDrawableSize(width: 800, height: 600)
        let settings = RenderShadowSettings(enabled: true, directionalCascadeCount: 3)
        let disabled = renderer.makeShadowAtlasPlan(scene: scene, drawableSize: size, enabled: false, settings: settings)
        #expect(!disabled.uniforms.isEnabled)
        #expect(disabled.uniforms.cameraPositionAndPadding == SIMD4<Float>(0, 0, 8, 1))
        let initial = renderer.makeShadowAtlasPlan(scene: scene, drawableSize: size, enabled: true, settings: settings)
        #expect(initial.lights.count == 3)
        scene.camera.fovYRadians = .pi / 3
        let differentFOV = renderer.makeShadowAtlasPlan(scene: scene, drawableSize: size, enabled: true, settings: settings)
        #expect(initial.uniforms.lightViewProjection0 == differentFOV.uniforms.lightViewProjection0)
        scene.camera.orthographicHeight *= 2
        let expanded = renderer.makeShadowAtlasPlan(scene: scene, drawableSize: size, enabled: true, settings: settings)
        #expect(initial.uniforms.lightViewProjection0 != expanded.uniforms.lightViewProjection0)
    }

    @Test("orthographic renderer uses drawable aspect and a parallel grid plane")
    func orthographicCameraMatricesAndGridPlane() {
        var camera = RenderCamera(eye: SIMD3<Float>(0, 0, 5), target: .zero,
                                  projection: .orthographic, orthographicHeight: 4)
        let matrices = RenderCameraMatrices.make(scene: RenderScene(camera: camera, instances: []),
            drawableSize: RenderDrawableSize(width: 200, height: 100))
        #expect(matrices.projection.columns.0.x == 0.25)
        #expect(matrices.projection.columns.1.y == 0.5)
        #expect(matrices.projection.columns.3.w == 1)
        #expect(EditorGridPlane.make(camera: camera).normal == SIMD3<Float>(0, 0, 1))
        camera.eye = SIMD3<Float>(5, 0, 0)
        #expect(EditorGridPlane.make(camera: camera).normal == SIMD3<Float>(-1, 0, 0))
        camera.eye = SIMD3<Float>(0, 5, 0)
        #expect(EditorGridPlane.make(camera: camera).normal == SIMD3<Float>(0, -1, 0))
        camera.projection = .perspective
        camera.eye = SIMD3<Float>(0, 0, 5)
        #expect(EditorGridPlane.make(camera: camera).normal == SIMD3<Float>(0, -1, 0))
    }

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

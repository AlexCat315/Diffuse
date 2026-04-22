import SceneRuntime
import Testing
import simd

@Suite("RenderExtraction")
struct RenderExtractionTests {
    @Test("renderExtract collects visible mesh instances and the active camera")
    func renderExtractCollectsVisibleMeshesAndActiveCamera() {
        var runtime = SceneRuntime()

        let camera = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 3, 8)), for: camera)
        _ = runtime.setComponent(
            CameraComponent(target: SIMD3<Float>(0, 1, 0), isActive: true),
            for: camera
        )

        let parent = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(1, 0, 0)), for: parent)
        _ = runtime.setComponent(RenderMeshComponent(meshIndex: 1), for: parent)

        let child = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 2, 0)), for: child)
        _ = runtime.setComponent(RenderMeshComponent(meshIndex: 0), for: child)
        _ = runtime.setParent(parent, for: child)

        let hidden = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(4, 4, 4)), for: hidden)
        _ = runtime.setComponent(RenderMeshComponent(meshIndex: 2, isVisible: false), for: hidden)

        _ = runtime.tick()

        guard let extracted = runtime.extractedRenderScene else {
            Issue.record("expected extracted render scene resource")
            return
        }

        #expect(extracted.activeCameraEntity == camera)
        #expect(extracted.scene.camera.eye == SIMD3<Float>(0, 3, 8))
        #expect(extracted.scene.camera.target == SIMD3<Float>(0, 1, 0))
        #expect(extracted.instanceEntities == [parent, child])
        #expect(translation(of: extracted.scene.instances[0].transform) == SIMD3<Float>(1, 0, 0))
        #expect(translation(of: extracted.scene.instances[1].transform) == SIMD3<Float>(1, 2, 0))
    }

    @Test("renderExtract falls back to the default camera when the world has no camera entity")
    func renderExtractFallsBackToDefaultCamera() {
        var runtime = SceneRuntime()

        let mesh = runtime.createEntity()
        _ = runtime.setComponent(RenderMeshComponent(meshIndex: 0), for: mesh)

        _ = runtime.tick()

        guard let extracted = runtime.extractedRenderScene else {
            Issue.record("expected extracted render scene resource")
            return
        }

        #expect(extracted.activeCameraEntity == nil)
        #expect(extracted.scene.camera.eye == RenderCamera.fallbackPerspective.eye)
        #expect(extracted.instanceEntities == [mesh])
        #expect(translation(of: extracted.scene.instances[0].transform) == .zero)
    }
}

private func translation(of matrix: simd_float4x4) -> SIMD3<Float> {
    SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
}
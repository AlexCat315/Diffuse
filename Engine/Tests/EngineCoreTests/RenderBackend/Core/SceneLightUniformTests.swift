@testable import RenderBackend
import SceneRuntime
import simd
import Testing

@Suite("SceneLightUniforms")
struct SceneLightUniformTests {
    @Test("packs render scene lights into the GPU contract")
    func packsRenderSceneLights() {
        let scene = RenderScene(
            camera: RenderCamera(eye: SIMD3<Float>(0, 0, 5)),
            lights: [
                RenderLight(type: .spot,
                            position: SIMD3<Float>(1, 2, 3),
                            direction: SIMD3<Float>(0, -2, 0),
                            color: SIMD3<Float>(0.8, 0.7, 0.6),
                            intensity: 3,
                            range: 12,
                            spotInnerAngleRadians: 0.25,
                            spotOuterAngleRadians: 0.75)
            ],
            environment: RenderEnvironment(ambientColor: SIMD3<Float>(0.2, 0.3, 0.4),
                                           ambientIntensity: 0.5,
                                           exposure: 1.25)
        )

        let uniforms = SceneLightUniforms(scene: scene)

        #expect(SceneLightUniforms.byteSize == UInt64(MemoryLayout<SceneLightUniforms>.stride))
        #expect(uniforms.ambientColorAndIntensity == SIMD4<Float>(0.2, 0.3, 0.4, 0.5))
        #expect(uniforms.exposureAndLightCount == SIMD4<Float>(1.25, 1, 0, 0))
        #expect(uniforms.light0.positionAndType == SIMD4<Float>(1, 2, 3, 2))
        #expect(uniforms.light0.directionAndRange == SIMD4<Float>(0, -1, 0, 12))
        #expect(uniforms.light0.colorAndIntensity == SIMD4<Float>(0.8, 0.7, 0.6, 3))
        #expect(uniforms.light0.spotAnglesAndPadding == SIMD4<Float>(0.25, 0.75, 0, 0))
        #expect(uniforms.light1 == .zero)
    }

    @Test("packs directional shadow slots into light uniforms")
    func packsDirectionalShadowSlots() {
        let scene = RenderScene(
            camera: RenderCamera(eye: SIMD3<Float>(0, 0, 5)),
            lights: [
                RenderLight(type: .directional,
                            direction: SIMD3<Float>(0, -1, 0),
                            intensity: 1),
                RenderLight(type: .directional,
                            direction: SIMD3<Float>(1, -1, 0),
                            intensity: 2),
            ]
        )

        let uniforms = SceneLightUniforms(scene: scene, shadowSlotsByLightIndex: [0: 1, 1: 0])

        #expect(uniforms.light0.spotAnglesAndPadding.z == 2)
        #expect(uniforms.light1.spotAnglesAndPadding.z == 1)
    }
}

@testable import EditorApp
import CinematicRenderer
import SceneRuntime
import SIMDCompat
import Testing

@Suite("Render pipeline editor integration")
struct RenderPipelineTests {
    @Test("render inputs reject silent fallbacks and unsafe ranges")
    func validatesInputs() {
        #expect(validateRenderPipelineRequest(width: "640", height: "480", samples: "64")
            == .success(RenderPipelineRequest(width: 640, height: 480, samples: 64)))
        #expect(validateRenderPipelineRequest(width: "wide", height: "480", samples: "64")
            == .failure(.invalidInteger))
        #expect(validateRenderPipelineRequest(width: "8192", height: "480", samples: "64")
            == .failure(.dimensionsOutOfRange))
        #expect(validateRenderPipelineRequest(width: "640", height: "480", samples: "0")
            == .failure(.samplesOutOfRange))
    }

    @Test("offline geometry is built from current render instances")
    func buildsCurrentSceneGeometry() {
        let camera = RenderCamera(eye: SIMD3<Float>(0, 0, 2), target: .zero)
        let scene = RenderScene(camera: camera,
                                instances: [RenderInstance(meshIndex: 0,
                                                           transform: matrix_identity_float4x4)])
        let geometry = RenderScenePathTraceGeometry(scene: scene)

        #expect(geometry.triangleCount == 12)
        let hit = geometry.intersect(ray: Ray(origin: camera.eye,
                                              direction: SIMD3<Float>(0, 0, -1)))
        #expect(hit != nil)
        #expect(abs((hit?.t ?? 0) - 1.5) < 0.001)
    }
}

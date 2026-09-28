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
        #expect(validateRenderPipelineRequest(width: "1600", height: "1000", samples: "40")
            == .success(RenderPipelineRequest(width: 1600, height: 1000, samples: 40)))
        #expect(validateRenderPipelineRequest(width: "1600", height: "1000", samples: "41")
            == .failure(.workloadTooLarge))
        #expect(validateRenderPipelineRequest(width: "2048", height: "2048", samples: "1024")
            == .failure(.workloadTooLarge))
    }

    @Test("render estimates image-buffer memory and presets stay in budget")
    func estimatesAndPresets() {
        #expect(estimateRenderPipelineInputs(width: "1600", height: "1000", samples: "40")
                == RenderPipelineEstimate(pathSampleCount: 64_000_000, imageBufferMiB: 43))
        #expect(estimateRenderPipelineInputs(width: "wide", height: "480", samples: "64") == nil)

        for preset in RenderPipelinePreset.allCases {
            let result = validateRenderPipelineRequest(width: String(preset.width),
                                                       height: String(preset.height),
                                                       samples: String(preset.samples))
            #expect(result == .success(RenderPipelineRequest(width: preset.width,
                                                             height: preset.height,
                                                             samples: preset.samples)))
        }
        #expect(RenderPipelinePreset.preview.matches(width: "320", height: "240", samples: "16"))
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

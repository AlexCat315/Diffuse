import CinematicRenderer
import ColorPipeline
import Foundation
import EXRIO
import simd

final class RenderPipelineRunner: @unchecked Sendable {

    struct Config: Sendable {
        var width: Int = 640
        var height: Int = 480
        var samplesPerPixel: Int = 64
        var maxBounces: Int = 4
        var outputPath: String = "/tmp/guava_render.exr"
    }

    struct Progress: Sendable {
        let completed: Int
        let total: Int
        var fraction: Float { total > 0 ? Float(completed) / Float(total) : 0 }
    }

    private let config: Config
    private let queue = DispatchQueue(label: "com.guava.renderpipeline")

    init(config: Config = Config()) {
        self.config = config
    }

    func run(
        scene: any SceneGeometry = SimpleTestScene(),
        onProgress: @escaping @Sendable (Progress) -> Void,
        onComplete: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        let cfg = config
        queue.async {
            let tracer = PathTracer(config: PathTracerConfig(
                maxBounces: cfg.maxBounces,
                samplesPerPixel: cfg.samplesPerPixel))
            var fb = [Float](repeating: 0, count: cfg.width * cfg.height * 3)
            let cam = SIMD3<Float>(2.5, 2.0, 3.5)
            let target = SIMD3<Float>(0, 0.7, 0)
            let fwd = simd_normalize(target - cam)
            let up = SIMD3<Float>(0, 1, 0)
            let geo = scene

            for s in 0..<cfg.samplesPerPixel {
                tracer.accumulatePass(into: &fb, width: cfg.width, height: cfg.height,
                                     cameraOrigin: cam, cameraForward: fwd, cameraUp: up,
                                     geometry: geo)
                DispatchQueue.main.async {
                    onProgress(Progress(completed: s + 1, total: cfg.samplesPerPixel))
                }
            }

            var rgba = [Float](repeating: 0, count: cfg.width * cfg.height * 4)
            for i in 0..<(cfg.width * cfg.height) {
                rgba[i * 4 + 0] = fb[i * 3 + 0]
                rgba[i * 4 + 1] = fb[i * 3 + 1]
                rgba[i * 4 + 2] = fb[i * 3 + 2]
                rgba[i * 4 + 3] = 1.0
            }
            _ = ViewTransform().apply(to: &rgba, width: cfg.width, height: cfg.height, using: nil)
            do {
                let writer = try EXRWriter(path: cfg.outputPath, width: cfg.width, height: cfg.height)
                writer.addLayer(EXRWriter.Layer(name: "beauty", channels: ["R", "G", "B", "A"], pixelType: .float))
                _ = writer.setPixels(rgba, for: "beauty")
                try writer.write()
                DispatchQueue.main.async { onComplete(.success(cfg.outputPath)) }
            } catch {
                DispatchQueue.main.async { onComplete(.failure(error)) }
            }
        }
    }
}

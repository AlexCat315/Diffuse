import CinematicRenderer
import ColorPipeline
import Foundation
import EXRIO
import SceneRuntime
import SIMDCompat

enum RenderPipelineRunnerError: LocalizedError {
    case cancelled

    var errorDescription: String? {
        switch self {
        case .cancelled: return L("Render cancelled.")
        }
    }
}

final class RenderPipelineRunner: @unchecked Sendable {

    struct Config: Sendable {
        var width: Int = 640
        var height: Int = 480
        var samplesPerPixel: Int = 64
        var maxBounces: Int = 4
        var outputPath: String = FileManager.default.temporaryDirectory
            .appendingPathComponent("guava_render.exr")
            .path
    }

    struct Progress: Sendable {
        let completed: Int
        let total: Int
        var fraction: Float { total > 0 ? Float(completed) / Float(total) : 0 }
    }

    private let config: Config
    private let queue = DispatchQueue(label: "com.guava.renderpipeline")
    private let stateLock = NSLock()
    private var isCancelled = false

    init(config: Config = Config()) {
        self.config = config
    }

    func cancel() {
        stateLock.lock()
        isCancelled = true
        stateLock.unlock()
    }

    func run(
        scene: any SceneGeometry,
        camera: RenderCamera,
        environmentColor: SIMD3<Float>,
        onProgress: @escaping @Sendable (Progress) -> Void,
        onComplete: @escaping @Sendable (Result<String, Error>) -> Void
    ) {
        let cfg = config
        stateLock.lock()
        isCancelled = false
        stateLock.unlock()
        queue.async {
            let tracer = PathTracer(config: PathTracerConfig(
                maxBounces: cfg.maxBounces,
                samplesPerPixel: cfg.samplesPerPixel,
                environmentColor: environmentColor))
            var fb = [Float](repeating: 0, count: cfg.width * cfg.height * 3)
            let forward = camera.target - camera.eye
            let fwd = simd_length(forward) > 0.000_001
                ? simd_normalize(forward)
                : SIMD3<Float>(0, 0, -1)
            let geo = scene

            for s in 0..<cfg.samplesPerPixel {
                if self.cancelledSnapshot() {
                    DispatchQueue.main.async { onComplete(.failure(RenderPipelineRunnerError.cancelled)) }
                    return
                }
                tracer.accumulatePass(into: &fb, width: cfg.width, height: cfg.height,
                                     cameraOrigin: camera.eye,
                                     cameraForward: fwd,
                                     cameraUp: camera.up,
                                     cameraFOVYRadians: camera.fovYRadians,
                                     cameraAspectRatio: Float(cfg.width) / Float(cfg.height),
                                     geometry: geo)
                DispatchQueue.main.async {
                    onProgress(Progress(completed: s + 1, total: cfg.samplesPerPixel))
                }
            }

            if self.cancelledSnapshot() {
                DispatchQueue.main.async { onComplete(.failure(RenderPipelineRunnerError.cancelled)) }
                return
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

    private func cancelledSnapshot() -> Bool {
        stateLock.lock()
        let value = isCancelled
        stateLock.unlock()
        return value
    }
}

import AssetPipeline
import EngineKernel
import Foundation
import RenderBackend
import SceneRuntime
import ScriptRuntime
import simd

struct SimulationFrameRequest: Sendable {
    let frameIndex: Int
    let deltaTime: Double
    let inputEvents: [InputEvent]
    let drawableSize: RenderDrawableSize
    let shouldRender: Bool
    let renderSettings: RenderSettings
}

struct SimulationFrameReport: Sendable {
    let frameIndex: Int
    let deltaTime: Double
    let inputSeconds: Double
    let simulationSeconds: Double
    let renderPrepareSeconds: Double
    let renderRequested: Bool
}

final class SimulationThread: @unchecked Sendable {
    private let runtime: any EngineRuntime
    private let ringBuffer: RingBuffer<RenderPacket>
    private let queue = DispatchQueue(label: "com.guava.engine.simulation", qos: .userInitiated)
    private let onFrameReady: @Sendable (SimulationFrameReport) -> Void
    private let onPacketPublished: @Sendable () -> Void

    private var sceneRuntime = SceneRuntime()
    private var scriptRuntime = ScriptRuntime()
    private var assetPipeline = AssetPipeline()
    private var simulationTimeSeconds: Double = 0

    init(
        runtime: any EngineRuntime,
        ringBuffer: RingBuffer<RenderPacket>,
        onFrameReady: @escaping @Sendable (SimulationFrameReport) -> Void,
        onPacketPublished: @escaping @Sendable () -> Void
    ) {
        self.runtime = runtime
        self.ringBuffer = ringBuffer
        self.onFrameReady = onFrameReady
        self.onPacketPublished = onPacketPublished
        seedDemoScene()
    }

    func submit(_ request: SimulationFrameRequest) {
        queue.async { [self] in
            process(request)
        }
    }

    func shutdown() {
        queue.sync {}
    }

    private func process(_ request: SimulationFrameRequest) {
        var inputSeconds = 0.0
        var simulationSeconds = 0.0
        var renderPrepareSeconds = 0.0

        var begin = CFAbsoluteTimeGetCurrent()
        runtime.tickInput(deltaTime: request.deltaTime)
        inputSeconds = CFAbsoluteTimeGetCurrent() - begin

        begin = CFAbsoluteTimeGetCurrent()
        runtime.tickSimulation(deltaTime: request.deltaTime)
        sceneRuntime.tick(deltaTime: request.deltaTime)
        scriptRuntime.tick(deltaTime: request.deltaTime)
        simulationTimeSeconds += request.deltaTime
        simulationSeconds = CFAbsoluteTimeGetCurrent() - begin

        begin = CFAbsoluteTimeGetCurrent()
        runtime.tickRenderPrepare(deltaTime: request.deltaTime)
        _ = assetPipeline.validatePath("Content")
        renderPrepareSeconds = CFAbsoluteTimeGetCurrent() - begin

        if request.shouldRender {
            let packet = RenderPacket(
                frameIndex: request.frameIndex,
                deltaTime: request.deltaTime,
                drawableSize: request.drawableSize,
                scene: sceneRuntime.renderScene,
                sceneSnapshot: sceneRuntime.snapshot,
                renderSettings: request.renderSettings,
                simulationTimeSeconds: simulationTimeSeconds
            )
            ringBuffer.publish(packet)
            onPacketPublished()
        }

        onFrameReady(
            SimulationFrameReport(
                frameIndex: request.frameIndex,
                deltaTime: request.deltaTime,
                inputSeconds: inputSeconds,
                simulationSeconds: simulationSeconds,
                renderPrepareSeconds: renderPrepareSeconds,
                renderRequested: request.shouldRender
            )
        )
    }

    private func seedDemoScene() {
        sceneRuntime.bootstrapEditorPreviewScene()
    }
}

import AssetPipeline
import AudioRuntime
import EngineKernel
import Foundation
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

struct SimulationFrameRequest: Sendable {
    let frameIndex: Int
    let deltaTime: Double
    let inputEvents: [InputEvent]
    let drawableSize: RenderDrawableSize
    let shouldRender: Bool
    let renderSettings: RenderSettings
    let renderSceneOverride: RenderScene?
    let jointPaletteOverride: JointPaletteMap?

    init(
        frameIndex: Int,
        deltaTime: Double,
        inputEvents: [InputEvent],
        drawableSize: RenderDrawableSize,
        shouldRender: Bool,
        renderSettings: RenderSettings,
        renderSceneOverride: RenderScene? = nil,
        jointPaletteOverride: JointPaletteMap? = nil
    ) {
        self.frameIndex = frameIndex
        self.deltaTime = deltaTime
        self.inputEvents = inputEvents
        self.drawableSize = drawableSize
        self.shouldRender = shouldRender
        self.renderSettings = renderSettings
        self.renderSceneOverride = renderSceneOverride
        self.jointPaletteOverride = jointPaletteOverride
    }
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
    private let onKernelPhase: @Sendable (EngineKernelPhase, EngineKernelPhaseContext) -> Void
    private let onFrameReady: @Sendable (SimulationFrameReport) -> Void
    private let onPacketPublished: @Sendable () -> Void

    private var sceneRuntime = SceneRuntime()
    private var scriptRuntime = ScriptRuntime()
    private var assetPipeline = AssetPipeline()
    private var simulationTimeSeconds: Double = 0

    init(
        runtime: any EngineRuntime,
        ringBuffer: RingBuffer<RenderPacket>,
        onKernelPhase: @escaping @Sendable (EngineKernelPhase, EngineKernelPhaseContext) -> Void = { _, _ in },
        onFrameReady: @escaping @Sendable (SimulationFrameReport) -> Void,
        onPacketPublished: @escaping @Sendable () -> Void
    ) {
        self.runtime = runtime
        self.ringBuffer = ringBuffer
        self.onKernelPhase = onKernelPhase
        self.onFrameReady = onFrameReady
        self.onPacketPublished = onPacketPublished
        sceneRuntime.setScriptDriver(scriptRuntime)
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
        let frameContext = EngineKernelPhaseContext(
            frameIndex: UInt64(request.frameIndex),
            deltaTime: request.deltaTime,
            inputEvents: request.inputEvents
        )

        var begin = Date().timeIntervalSinceReferenceDate
        onKernelPhase(.input, frameContext)
        runtime.tickInput(deltaTime: request.deltaTime, inputEvents: request.inputEvents)
        inputSeconds = Date().timeIntervalSinceReferenceDate - begin

        begin = Date().timeIntervalSinceReferenceDate
        onKernelPhase(.simulation, frameContext)
        runtime.tickSimulation(deltaTime: request.deltaTime)
        sceneRuntime.tick(
            deltaTime: request.deltaTime,
            frameIndex: UInt64(request.frameIndex),
            inputEvents: request.inputEvents
        )
        AudioEngine.shared.tick(scene: sceneRuntime)
        simulationTimeSeconds += request.deltaTime
        simulationSeconds = Date().timeIntervalSinceReferenceDate - begin

        begin = Date().timeIntervalSinceReferenceDate
        onKernelPhase(.renderPrepare, frameContext)
        runtime.tickRenderPrepare(deltaTime: request.deltaTime)
        _ = assetPipeline.validatePath("Content")
        renderPrepareSeconds = Date().timeIntervalSinceReferenceDate - begin

        if request.shouldRender {
            let scene = request.renderSceneOverride ?? sceneRuntime.renderScene
            let paletteMap = request.jointPaletteOverride
                ?? sceneRuntime.resource(JointPaletteMap.self)
                ?? JointPaletteMap()
            let canvas = sceneRuntime.resource(InGameCanvas.self) ?? InGameCanvas()
            let packet = RenderPacket(
                frameIndex: request.frameIndex,
                deltaTime: request.deltaTime,
                drawableSize: request.drawableSize,
                scene: scene,
                sceneSnapshot: sceneRuntime.snapshot,
                renderSettings: request.renderSettings,
                simulationTimeSeconds: simulationTimeSeconds,
                jointPaletteMap: paletteMap,
                inGameCanvas: canvas
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

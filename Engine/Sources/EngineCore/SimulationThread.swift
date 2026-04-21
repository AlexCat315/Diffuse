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
                scene: buildRenderScene(frameIndex: request.frameIndex),
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

    private func buildRenderScene(frameIndex: Int) -> RenderScene {
        let t = Float(frameIndex) * 0.015
        var instances: [RenderInstance] = []

        instances.append(RenderInstance(meshIndex: 1, transform: rotationY(t)))
        for k in 0..<4 {
            let angle = Float(k) * (.pi / 2) + t * 0.5
            let radius: Float = 2.5
            let position = SIMD3<Float>(
                cos(angle) * radius,
                sin(t * 0.4 + Float(k)) * 0.4,
                sin(angle) * radius
            )
            let transform = translation(position) * rotationY(t * 1.5 + Float(k)) * uniformScale(0.4)
            instances.append(RenderInstance(meshIndex: 0, transform: transform))
        }

        return RenderScene(
            camera: RenderCamera(eye: SIMD3<Float>(0, 2.0, 5.5), target: .zero),
            instances: instances
        )
    }
}

private func translation(_ t: SIMD3<Float>) -> simd_float4x4 {
    simd_float4x4(rows: [
        SIMD4<Float>(1, 0, 0, t.x),
        SIMD4<Float>(0, 1, 0, t.y),
        SIMD4<Float>(0, 0, 1, t.z),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}

private func uniformScale(_ s: Float) -> simd_float4x4 {
    simd_float4x4(diagonal: SIMD4<Float>(s, s, s, 1))
}

private func rotationY(_ angle: Float) -> simd_float4x4 {
    let c = cos(angle)
    let s = sin(angle)
    return simd_float4x4(rows: [
        SIMD4<Float>(c, 0, s, 0),
        SIMD4<Float>(0, 1, 0, 0),
        SIMD4<Float>(-s, 0, c, 0),
        SIMD4<Float>(0, 0, 0, 1),
    ])
}

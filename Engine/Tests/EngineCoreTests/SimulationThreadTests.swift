import Foundation
import RenderBackend
import SceneRuntime
import Testing
import simd
@testable import EngineCore

@Suite("SimulationThread")
struct SimulationThreadTests {
    @Test("SimulationThread publishes render packets extracted from SceneRuntime")
    func simulationThreadPublishesExtractedScene() {
        let ring = RingBuffer<RenderPacket>()
        let runtime = IdleRuntime()
        let frameReady = DispatchSemaphore(value: 0)
        let packetPublished = DispatchSemaphore(value: 0)

        let thread = SimulationThread(
            runtime: runtime,
            ringBuffer: ring,
            onFrameReady: { _ in
                frameReady.signal()
            },
            onPacketPublished: {
                packetPublished.signal()
            }
        )

        thread.submit(
            SimulationFrameRequest(
                frameIndex: 0,
                deltaTime: 1.0 / 60.0,
                inputEvents: [],
                drawableSize: .init(width: 1280, height: 720),
                shouldRender: true,
                renderSettings: .init()
            )
        )

        let publishResult = packetPublished.wait(timeout: .now() + 2)
        #expect(publishResult == .success)

        guard let packet = ring.consumeLatest() else {
            Issue.record("expected a render packet from the simulation thread")
            thread.shutdown()
            return
        }

        #expect(packet.scene.camera.eye == SIMD3<Float>(0, 2.4, 7.5))
        #expect(packet.scene.instances.count == 2)
        #expect(translation(of: packet.scene.instances[0].transform) == SIMD3<Float>(0, 1, 0))
        #expect(translation(of: packet.scene.instances[1].transform) == SIMD3<Float>(0, -1, 0))

        let frameReadyResult = frameReady.wait(timeout: .now() + 2)
        #expect(frameReadyResult == .success)

        thread.shutdown()
    }
}

private struct IdleRuntime: EngineRuntime {
    func initialize() {}
    func tickInput(deltaTime: Double) {}
    func tickSimulation(deltaTime: Double) {}
    func tickRenderPrepare(deltaTime: Double) {}
    func tickRenderSubmit(deltaTime: Double) {}
    func shutdown() {}
}

private func translation(of matrix: simd_float4x4) -> SIMD3<Float> {
    SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
}
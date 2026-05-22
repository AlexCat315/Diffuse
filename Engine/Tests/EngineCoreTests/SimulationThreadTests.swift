import Foundation
import EngineKernel
import RenderBackend
import SceneRuntime
import Testing
import SIMDCompat
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

    @Test("jointPaletteOverride in request takes precedence over internal scene palette")
    func jointPaletteOverrideAppearsInPublishedPacket() {
        let ring = RingBuffer<RenderPacket>()
        let runtime = IdleRuntime()
        let packetPublished = DispatchSemaphore(value: 0)

        let thread = SimulationThread(
            runtime: runtime,
            ringBuffer: ring,
            onFrameReady: { _ in },
            onPacketPublished: { packetPublished.signal() }
        )

        let sentinelEntity = EntityID(index: 99, generation: 1)
        let override = JointPaletteMap(palettes: [
            sentinelEntity: JointPalette(matrices: [matrix_identity_float4x4])
        ])

        thread.submit(
            SimulationFrameRequest(
                frameIndex: 0,
                deltaTime: 1.0 / 60.0,
                inputEvents: [],
                drawableSize: .init(width: 64, height: 64),
                shouldRender: true,
                renderSettings: .init(),
                jointPaletteOverride: override
            )
        )

        #expect(packetPublished.wait(timeout: .now() + 2) == .success)

        guard let packet = ring.consumeLatest() else {
            Issue.record("expected a render packet")
            thread.shutdown()
            return
        }

        #expect(packet.jointPaletteMap.palette(for: sentinelEntity) != nil)
        #expect(packet.jointPaletteMap.palette(for: sentinelEntity)?.matrices.isEmpty == false)

        thread.shutdown()
    }

    @Test("SimulationThread forwards input events into input phase and SceneRuntime tick")
    func simulationThreadForwardsInputEvents() {
        let ring = RingBuffer<RenderPacket>()
        let runtime = RecordingRuntime()
        let frameReady = DispatchSemaphore(value: 0)
        let packetPublished = DispatchSemaphore(value: 0)
        let phaseRecorder = PhaseRecorder()
        let inputEvents: [InputEvent] = [
            .windowFocusGained,
            .mouseMotion(.init(x: 10, y: 20, deltaX: 1, deltaY: -2))
        ]

        let thread = SimulationThread(
            runtime: runtime,
            ringBuffer: ring,
            onKernelPhase: { phase, context in
                phaseRecorder.append(phase: phase, context: context)
            },
            onFrameReady: { _ in
                frameReady.signal()
            },
            onPacketPublished: {
                packetPublished.signal()
            }
        )

        thread.submit(
            SimulationFrameRequest(
                frameIndex: 7,
                deltaTime: 1.0 / 30.0,
                inputEvents: inputEvents,
                drawableSize: .init(width: 1280, height: 720),
                shouldRender: true,
                renderSettings: .init()
            )
        )

        #expect(packetPublished.wait(timeout: .now() + 2) == .success)
        #expect(frameReady.wait(timeout: .now() + 2) == .success)

        let recordedInput = runtime.lastInputCall()
        #expect(recordedInput?.deltaTime == 1.0 / 30.0)
        #expect(recordedInput?.eventCount == inputEvents.count)

        guard let packet = ring.consumeLatest() else {
            Issue.record("expected a render packet from the simulation thread")
            thread.shutdown()
            return
        }
        #expect(packet.sceneSnapshot.revision > 0)

        let phases = phaseRecorder.snapshot()
        #expect(phases.map(\.phase) == [.input, .simulation, .renderPrepare])
        #expect(phases.allSatisfy { $0.context.frameIndex == 7 })
        #expect(phases[0].context.inputEvents.count == inputEvents.count)
        #expect(phases[1].context.inputEvents.count == inputEvents.count)
        #expect(phases[2].context.inputEvents.count == inputEvents.count)

        thread.shutdown()
    }
}

private struct IdleRuntime: EngineRuntime {
    func initialize() {}
    func tickInput(deltaTime: Double, inputEvents: [InputEvent]) {}
    func tickSimulation(deltaTime: Double) {}
    func tickRenderPrepare(deltaTime: Double) {}
    func tickRenderSubmit(deltaTime: Double) {}
    func shutdown() {}
}

private final class RecordingRuntime: @unchecked Sendable, EngineRuntime {
    private let lock = NSLock()
    private var lastInputDeltaTime: Double?
    private var lastInputEventCount = 0

    func initialize() {}

    func tickInput(deltaTime: Double, inputEvents: [InputEvent]) {
        lock.withLock {
            lastInputDeltaTime = deltaTime
            lastInputEventCount = inputEvents.count
        }
    }

    func tickSimulation(deltaTime: Double) {}
    func tickRenderPrepare(deltaTime: Double) {}
    func tickRenderSubmit(deltaTime: Double) {}
    func shutdown() {}

    func lastInputCall() -> (deltaTime: Double, eventCount: Int)? {
        lock.withLock {
            guard let lastInputDeltaTime else { return nil }
            return (lastInputDeltaTime, lastInputEventCount)
        }
    }
}

private final class PhaseRecorder: @unchecked Sendable {
    struct Entry: Sendable {
        var phase: EngineKernelPhase
        var context: EngineKernelPhaseContext
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func append(phase: EngineKernelPhase, context: EngineKernelPhaseContext) {
        lock.withLock {
            entries.append(Entry(phase: phase, context: context))
        }
    }

    func snapshot() -> [Entry] {
        lock.withLock { entries }
    }
}

private func translation(of matrix: simd_float4x4) -> SIMD3<Float> {
    SIMD3<Float>(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
}

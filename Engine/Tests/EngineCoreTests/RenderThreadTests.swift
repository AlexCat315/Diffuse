import Foundation
import EngineKernel
import RenderBackend
import SceneRuntime
import NativeRHI
import Testing
import SIMDCompat
@testable import EngineCore

@Suite("RenderThread")
struct RenderThreadTests {
    @Test("RenderThread consumes real packets through the NativeRHI grid renderer",
          .enabled(if: ProcessInfo.processInfo.environment["GUAVA_RUN_GPU_SMOKE_TESTS"] == "1",
                   "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the GPU test"))
    func nativeGridRenderPacketIntegration() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: false))
        let consumer = try NativeGridRenderer(device: device)
        let buffer = LatestValueBuffer<RenderPacket>()
        let rendered = DispatchSemaphore(value: 0)
        let reportRecorder = RenderReportRecorder()
        let thread = RenderThread(runtime: NoopRuntime(), packetBuffer: buffer, consumer: consumer,
            onFrameRendered: { report in reportRecorder.append(report); rendered.signal() })
        thread.start(); defer { thread.shutdown() }
        var packet = Self.makePacket(frameIndex: 17)
        packet.drawableSize = RenderDrawableSize(width: 128, height: 96)
        packet.scene.instances = []; packet.renderSettings.enableEditorGrid = true
        buffer.publish(packet); thread.requestRender()
        #expect(rendered.wait(timeout: .now() + 5) == .success)
        thread.shutdown(); try device.waitUntilIdle()
        #expect(consumer.lastError == nil)
        #expect(consumer.currentFrameStats().frameIndex == 17)
        #expect(consumer.currentFrameStats().passDrawCallCounts[.editorGrid] == 1)
        #expect(consumer.colorTexture != nil)
        let surface = consumer.currentViewportSurfaceState()
        #expect(surface.isValid)
        #expect(surface.region.size == packet.drawableSize)
        let reported = try #require(reportRecorder.snapshot().first?.viewportSurfaceState)
        #expect(reported == surface && reported.image === surface.image)
        if case .native(let resource) = surface.image?.storage {
            #expect(resource.texture == consumer.colorTexture)
        } else { Issue.record("render thread must publish an owned native image") }
    }
    @Test("RenderThread consumes indexed scene packets through NativeRenderer",
          .enabled(if: ProcessInfo.processInfo.environment["GUAVA_RUN_GPU_SMOKE_TESTS"] == "1",
                   "set GUAVA_RUN_GPU_SMOKE_TESTS=1 to run the GPU test"))
    func nativeSceneRenderPacketIntegration() throws {
        let device = try Device.make(DeviceConfig(preferredBackends: [.metal], enableValidation: false))
        let consumer = try NativeRenderer(device: device)
        let buffer = LatestValueBuffer<RenderPacket>()
        let rendered = DispatchSemaphore(value: 0)
        let thread = RenderThread(runtime: NoopRuntime(), packetBuffer: buffer, consumer: consumer,
            onFrameRendered: { _ in rendered.signal() })
        thread.start(); defer { thread.shutdown() }
        var packet = Self.makePacket(frameIndex: 21)
        packet.drawableSize = RenderDrawableSize(width: 128, height: 96)
        packet.renderSettings.stage = .r2MultiObjectDepth
        packet.renderSettings.debugViewMode = .unlit
        packet.renderSettings.enableEditorGrid = true
        buffer.publish(packet); thread.requestRender()
        #expect(rendered.wait(timeout: .now() + 5) == .success)
        thread.shutdown(); try device.waitUntilIdle()
        #expect(consumer.lastError == nil)
        #expect(consumer.lastFrameStats.frameIndex == 21)
        #expect(consumer.lastFrameStats.passDrawCallCounts[.basePass] == 1)
        #expect(consumer.lastFrameStats.passDrawCallCounts[.depthPrepass] == 1)
        #expect(consumer.lastFrameStats.passDrawCallCounts[.editorGrid] == 1)
        #expect(consumer.lastFrameStats.submittedMeshTriangleCount == 12)
    }

    @Test("LatestValueBuffer returns the latest published payload")
    func packetBufferReturnsLatestPayload() {
        let buffer = LatestValueBuffer<Int>()
        buffer.publish(1)
        buffer.publish(2)
        buffer.publish(3)

        #expect(buffer.consumeLatest() == 3)
        #expect(buffer.consumeLatest() == nil)
    }

    @Test("RenderThread drains a follow-up render request after the current pass")
    func renderThreadDrainsFollowUpRequest() {
        let buffer = LatestValueBuffer<RenderPacket>()
        let runtime = NoopRuntime()
        let consumer = TestConsumer()
        let rendered = FrameRecorder()
        let reports = DispatchSemaphore(value: 0)

        let thread = RenderThread(
            runtime: runtime,
            packetBuffer: buffer,
            consumer: consumer,
            onFrameRendered: { report in
                rendered.append(report.frameIndex)
                reports.signal()
            }
        )
        thread.start()

        buffer.publish(Self.makePacket(frameIndex: 0))
        thread.requestRender()
        consumer.waitUntilRenderStarts()

        buffer.publish(Self.makePacket(frameIndex: 1))
        thread.requestRender()
        consumer.releaseFirstRender()
        for _ in 0..<2 {
            #expect(reports.wait(timeout: .now() + 2) == .success)
        }

        #expect(rendered.snapshot() == [0, 1])

        thread.shutdown()
    }

    @Test("RenderThread emits render submit kernel phase before rendering")
    func renderThreadEmitsRenderSubmitPhase() {
        let buffer = LatestValueBuffer<RenderPacket>()
        let runtime = NoopRuntime()
        let consumer = FastConsumer()
        let phaseRecorder = PhaseRecorder()
        let rendered = DispatchSemaphore(value: 0)

        let thread = RenderThread(
            runtime: runtime,
            packetBuffer: buffer,
            onKernelPhase: { phase, context in
                phaseRecorder.append(phase: phase, context: context)
            },
            consumer: consumer,
            onFrameRendered: { _ in
                rendered.signal()
            }
        )
        thread.start()

        buffer.publish(Self.makePacket(frameIndex: 9))
        thread.requestRender()

        #expect(rendered.wait(timeout: .now() + 2) == .success)
        let phases = phaseRecorder.snapshot()
        #expect(phases.count == 1)
        #expect(phases.first?.phase == .renderSubmit)
        #expect(phases.first?.context.frameIndex == 9)
        #expect(phases.first?.context.deltaTime == 1.0 / 60.0)
        #expect(phases.first?.context.inputEvents.isEmpty == true)

        thread.shutdown()
    }

    @Test("RenderThread reports drained GPU particle simulation events")
    func renderThreadReportsDrainedGPUParticleSimulationEvents() {
        let buffer = LatestValueBuffer<RenderPacket>()
        let runtime = NoopRuntime()
        let snapshot = GPUParticleSimulationEventSnapshot(
            slot: 0,
            emitterRawValue: EntityID(index: 2, generation: 1).rawValue,
            eventCapacity: 4,
            totalEventCount: 1,
            droppedEventCount: 0,
            records: [
                GPUParticleSimulationEventRecord(
                    trigger: .death,
                    sourceIndex: 0,
                    position: .zero,
                    lifetime: 1,
                    velocity: .zero,
                    age: 1
                ),
            ]
        )
        let consumer = SnapshotConsumer(snapshots: [snapshot])
        let reportRecorder = RenderReportRecorder()
        let rendered = DispatchSemaphore(value: 0)

        let thread = RenderThread(
            runtime: runtime,
            packetBuffer: buffer,
            consumer: consumer,
            onFrameRendered: { report in
                reportRecorder.append(report)
                rendered.signal()
            }
        )
        thread.start()

        buffer.publish(Self.makePacket(frameIndex: 3))
        thread.requestRender()

        #expect(rendered.wait(timeout: .now() + 2) == .success)
        let report = reportRecorder.snapshot().first
        #expect(report?.particleSimulationEventSnapshots == [snapshot])
        #expect(consumer.drainCount() == 1)

        thread.shutdown()
    }

    private static func makePacket(frameIndex: Int) -> RenderPacket {
        RenderPacket(
            frameIndex: frameIndex,
            deltaTime: 1.0 / 60.0,
            drawableSize: .init(width: 1280, height: 720),
            scene: RenderScene(
                camera: RenderCamera(eye: SIMD3<Float>(0, 2, 5)),
                instances: [RenderInstance(meshIndex: 0, transform: matrix_identity_float4x4)]
            ),
            sceneSnapshot: SceneRuntimeSnapshot(entityCount: 1, revision: UInt64(frameIndex)),
            renderSettings: .init(),
            simulationTimeSeconds: Double(frameIndex) / 60.0
        )
    }
}

private struct NoopRuntime: EngineRuntime {
    func initialize() {}
    func tickInput(deltaTime: Double, inputEvents: [InputEvent]) {}
    func tickSimulation(deltaTime: Double) {}
    func tickRenderPrepare(deltaTime: Double) {}
    func tickRenderSubmit(deltaTime: Double) {}
    func shutdown() {}
}

private final class TestConsumer: RenderPacketConsumer, @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let renderCountLock = NSLock()
    private var renderCount = 0

    func initialize() {}

    func render(packet: RenderPacket) {
        let current = renderCountLock.withLock { () -> Int in
            renderCount += 1
            return renderCount
        }
        started.signal()
        if current == 1 {
            releaseFirst.wait()
        }
    }

    func currentFrameStats() -> RenderFrameStats {
        .init()
    }

    func currentViewportSurfaceState() -> ViewportSurfaceState {
        .init()
    }

    func waitUntilRenderStarts() {
        let result = started.wait(timeout: .now() + 2)
        #expect(result == .success)
    }

    func releaseFirstRender() {
        releaseFirst.signal()
    }

}

private final class FastConsumer: RenderPacketConsumer, @unchecked Sendable {
    func initialize() {}

    func render(packet: RenderPacket) {}

    func currentFrameStats() -> RenderFrameStats {
        .init()
    }

    func currentViewportSurfaceState() -> ViewportSurfaceState {
        .init()
    }
}

private final class SnapshotConsumer: RenderPacketConsumer, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [GPUParticleSimulationEventSnapshot]
    private var drained = 0

    init(snapshots: [GPUParticleSimulationEventSnapshot]) {
        self.snapshots = snapshots
    }

    func initialize() {}

    func render(packet: RenderPacket) {}

    func currentFrameStats() -> RenderFrameStats {
        .init()
    }

    func currentViewportSurfaceState() -> ViewportSurfaceState {
        .init()
    }

    func drainGPUParticleSimulationEventSnapshots(
        maxSnapshots: Int
    ) throws -> [GPUParticleSimulationEventSnapshot] {
        lock.withLock {
            drained += 1
            let count = min(max(0, maxSnapshots), snapshots.count)
            let result = Array(snapshots.prefix(count))
            snapshots.removeFirst(count)
            return result
        }
    }

    func drainCount() -> Int {
        lock.withLock { drained }
    }
}

private final class FrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Int] = []

    func append(_ frameIndex: Int) {
        lock.withLock {
            frames.append(frameIndex)
        }
    }

    func snapshot() -> [Int] {
        lock.withLock { frames }
    }
}

private final class RenderReportRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [RenderThreadReport] = []

    func append(_ report: RenderThreadReport) {
        lock.withLock {
            reports.append(report)
        }
    }

    func snapshot() -> [RenderThreadReport] {
        lock.withLock { reports }
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

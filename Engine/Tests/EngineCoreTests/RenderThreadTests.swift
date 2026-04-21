import Foundation
import RenderBackend
import SceneRuntime
import Testing
import simd
@testable import EngineCore

@Suite("RenderThread")
struct RenderThreadTests {
    @Test("RingBuffer returns the latest published payload")
    func ringBufferReturnsLatestPayload() {
        let ring = RingBuffer<Int>()
        ring.publish(1)
        ring.publish(2)
        ring.publish(3)

        #expect(ring.consumeLatest() == 3)
        #expect(ring.consumeLatest() == nil)
    }

    @Test("RenderThread drains a follow-up render request after the current pass")
    func renderThreadDrainsFollowUpRequest() {
        let ring = RingBuffer<RenderPacket>()
        let runtime = NoopRuntime()
        let consumer = TestConsumer()
        let rendered = FrameRecorder()

        let thread = RenderThread(
            runtime: runtime,
            ringBuffer: ring,
            consumer: consumer,
            onFrameRendered: { report in
                rendered.append(report.frameIndex)
            }
        )
        thread.start()

        ring.publish(Self.makePacket(frameIndex: 0))
        thread.requestRender()
        consumer.waitUntilRenderStarts()

        ring.publish(Self.makePacket(frameIndex: 1))
        thread.requestRender()
        consumer.releaseFirstRender()
        consumer.waitForRenderedFrames(count: 2)

        #expect(rendered.snapshot() == [0, 1])

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
    func tickInput(deltaTime: Double) {}
    func tickSimulation(deltaTime: Double) {}
    func tickRenderPrepare(deltaTime: Double) {}
    func tickRenderSubmit(deltaTime: Double) {}
    func shutdown() {}
}

private final class TestConsumer: RenderPacketConsumer, @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let rendered = DispatchSemaphore(value: 0)
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
        rendered.signal()
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

    func waitForRenderedFrames(count: Int) {
        for _ in 0..<count {
            let result = rendered.wait(timeout: .now() + 2)
            #expect(result == .success)
        }
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

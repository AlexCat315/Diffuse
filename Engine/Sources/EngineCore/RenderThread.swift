import Foundation
import EngineKernel
import RenderBackend

struct RenderThreadReport: Sendable {
    public var frameIndex: Int
    public var deltaTime: Double
    public var renderSubmitSeconds: Double
    public var stats: RenderFrameStats
    public var viewportSurfaceState: ViewportSurfaceState

    init(
        frameIndex: Int,
        deltaTime: Double,
        renderSubmitSeconds: Double,
        stats: RenderFrameStats,
        viewportSurfaceState: ViewportSurfaceState
    ) {
        self.frameIndex = frameIndex
        self.deltaTime = deltaTime
        self.renderSubmitSeconds = renderSubmitSeconds
        self.stats = stats
        self.viewportSurfaceState = viewportSurfaceState
    }
}

final class RenderThread: @unchecked Sendable {
    private struct State {
        var renderScheduled = false
        var rerenderRequested = false
        var isShutdown = false
    }

    private let runtime: any EngineRuntime
    private let ringBuffer: RingBuffer<RenderPacket>
    private let onKernelPhase: @Sendable (EngineKernelPhase, EngineKernelPhaseContext) -> Void
    private let consumer: any RenderPacketConsumer
    private let queue = DispatchQueue(label: "com.guava.engine.render", qos: .userInitiated)
    private let state = LockedState(State())
    private let onFrameRendered: @Sendable (RenderThreadReport) -> Void

    init(
        runtime: any EngineRuntime,
        ringBuffer: RingBuffer<RenderPacket>,
        onKernelPhase: @escaping @Sendable (EngineKernelPhase, EngineKernelPhaseContext) -> Void = { _, _ in },
        consumer: any RenderPacketConsumer,
        onFrameRendered: @escaping @Sendable (RenderThreadReport) -> Void
    ) {
        self.runtime = runtime
        self.ringBuffer = ringBuffer
        self.onKernelPhase = onKernelPhase
        self.consumer = consumer
        self.onFrameRendered = onFrameRendered
    }

    func start() {
        queue.sync {
            consumer.initialize()
        }
    }

    func requestRender() {
        let shouldSchedule = state.withLock { state -> Bool in
            guard !state.isShutdown else { return false }
            if state.renderScheduled {
                state.rerenderRequested = true
                return false
            }
            state.renderScheduled = true
            return true
        }
        guard shouldSchedule else { return }

        queue.async { [self] in
            runRenderLoop()
        }
    }

    func shutdown() {
        state.withLock { state in
            state.isShutdown = true
        }
        queue.sync {}
    }

    private func runRenderLoop() {
        while true {
            if state.withLock({ $0.isShutdown }) {
                state.withLock { $0.renderScheduled = false }
                return
            }

            guard let packet = ringBuffer.consumeLatest() else {
                let shouldContinue = state.withLock { state -> Bool in
                    if state.rerenderRequested {
                        state.rerenderRequested = false
                        return true
                    }
                    state.renderScheduled = false
                    return false
                }
                if shouldContinue {
                    continue
                }
                return
            }

            let begin = CFAbsoluteTimeGetCurrent()
            onKernelPhase(
                .renderSubmit,
                EngineKernelPhaseContext(frameIndex: UInt64(packet.frameIndex), deltaTime: packet.deltaTime)
            )
            runtime.tickRenderSubmit(deltaTime: packet.deltaTime)
            consumer.render(packet: packet)
            let renderSubmitSeconds = CFAbsoluteTimeGetCurrent() - begin

            onFrameRendered(
                RenderThreadReport(
                    frameIndex: packet.frameIndex,
                    deltaTime: packet.deltaTime,
                    renderSubmitSeconds: renderSubmitSeconds,
                    stats: consumer.currentFrameStats(),
                    viewportSurfaceState: consumer.currentViewportSurfaceState()
                )
            )

            let shouldContinue = state.withLock { state -> Bool in
                if state.rerenderRequested {
                    state.rerenderRequested = false
                    return true
                }
                state.renderScheduled = false
                return false
            }
            if !shouldContinue {
                return
            }
        }
    }
}

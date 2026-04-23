import EngineKernel
import Foundation
import RenderBackend
import RHIWGPU
import SceneRuntime

public enum TickPhase: CaseIterable, Sendable {
    case input
    case simulation
    case renderPrepare
    case renderSubmit
}

public struct PhaseTimings: Sendable {
    public var inputSeconds: Double = 0
    public var simulationSeconds: Double = 0
    public var renderPrepareSeconds: Double = 0
    public var renderSubmitSeconds: Double = 0

    public init() {}
}

public protocol EngineRuntime: Sendable {
    func initialize()
    func tickInput(deltaTime: Double, inputEvents: [InputEvent])
    func tickSimulation(deltaTime: Double)
    func tickRenderPrepare(deltaTime: Double)
    func tickRenderSubmit(deltaTime: Double)
    func shutdown()
}

private struct FrameTimingLedger {
    var partial: [Int: PhaseTimings] = [:]
    var lastCompleted: PhaseTimings = .init()

    mutating func beginFrame(_ frameIndex: Int) {
        partial[frameIndex] = .init()
    }

    mutating func updateSimulation(_ report: SimulationFrameReport) {
        var timings = partial[report.frameIndex] ?? .init()
        timings.inputSeconds = report.inputSeconds
        timings.simulationSeconds = report.simulationSeconds
        timings.renderPrepareSeconds = report.renderPrepareSeconds
        partial[report.frameIndex] = timings
        if !report.renderRequested {
            lastCompleted = timings
            partial.removeValue(forKey: report.frameIndex)
        }
        trim(before: report.frameIndex - 6)
    }

    mutating func completeRender(_ report: RenderThreadReport) {
        var timings = partial[report.frameIndex] ?? .init()
        timings.renderSubmitSeconds = report.renderSubmitSeconds
        lastCompleted = timings
        partial.removeValue(forKey: report.frameIndex)
        trim(before: report.frameIndex - 6)
    }

    private mutating func trim(before floor: Int) {
        partial = partial.filter { $0.key >= floor }
    }
}

private struct EngineHostState {
    var started = false
    var nextFrameIndex = 0
    var currentInputEvents: [InputEvent] = []
    var renderSettings: RenderSettings = .init()
    var renderStats: RenderFrameStats = .init()
    var viewportSurfaceState: ViewportSurfaceState = .init()
}

public final class EngineHost: @unchecked Sendable {
    private let runtime: any EngineRuntime
    private let kernel = LockedState(EngineKernelCoordinator())
    private let state = LockedState(EngineHostState())
    private let timings = LockedState(FrameTimingLedger())

    public let wgpuBackend: WGPUBackend

    private var ringBuffer: RingBuffer<RenderPacket>?
    private var simulationThread: SimulationThread?
    private var renderThread: RenderThread?

    public init(runtime: any EngineRuntime, wgpuBackend: WGPUBackend = WGPUBackend()) {
        self.runtime = runtime
        self.wgpuBackend = wgpuBackend
    }

    public var lastTimings: PhaseTimings {
        timings.withLock { $0.lastCompleted }
    }

    public var currentInputEvents: [InputEvent] {
        state.withLock { $0.currentInputEvents }
    }

    public func start(renderSurface: RenderSurfaceDescriptor? = nil,
                      enableViewportSurface: Bool = false) {
        let shouldStart = state.withLock { state -> Bool in
            guard !state.started else { return false }
            state.started = true
            return true
        }
        guard shouldStart else { return }

        runtime.initialize()
        kernel.withLock { $0.boot() }

        do {
            try wgpuBackend.initialize()
        } catch {
            fputs("[EngineHost] WGPU backend initialization failed: \(error)\n", stderr)
        }

        let ringBuffer = RingBuffer<RenderPacket>()
        self.ringBuffer = ringBuffer

        let consumer: (any RenderPacketConsumer)?
        if let renderSurface {
            consumer = WGPURenderer(backend: wgpuBackend, renderSurface: renderSurface)
        } else if enableViewportSurface {
            consumer = WGPURenderer(backend: wgpuBackend)
        } else {
            consumer = nil
        }

        let renderThread = consumer.map {
            RenderThread(
                runtime: runtime,
                ringBuffer: ringBuffer,
                onKernelPhase: { [weak self] phase, context in
                    self?.kernel.withLock { kernel in
                        _ = kernel.tick(phase: phase, context: context)
                    }
                },
                consumer: $0,
                onFrameRendered: { [weak self] report in
                    self?.handleRenderedFrame(report)
                }
            )
        }
        renderThread?.start()
        self.renderThread = renderThread

        self.simulationThread = SimulationThread(
            runtime: runtime,
            ringBuffer: ringBuffer,
            onKernelPhase: { [weak self] phase, context in
                self?.kernel.withLock { kernel in
                    _ = kernel.tick(phase: phase, context: context)
                }
            },
            onFrameReady: { [weak self] report in
                self?.handleSimulationFrame(report)
            },
            onPacketPublished: { [weak self] in
                self?.renderThread?.requestRender()
            }
        )
    }

    public func tick(
        deltaTime: Double,
        inputEvents: [InputEvent] = [],
        drawableSize: RenderDrawableSize = .init(),
        shouldRender: Bool = true,
        renderSceneOverride: RenderScene? = nil
    ) {
        let request = state.withLock { state -> SimulationFrameRequest? in
            guard state.started else { return nil }
            let frameIndex = state.nextFrameIndex
            state.nextFrameIndex += 1
            state.currentInputEvents = inputEvents
            return SimulationFrameRequest(
                frameIndex: frameIndex,
                deltaTime: deltaTime,
                inputEvents: inputEvents,
                drawableSize: drawableSize,
                shouldRender: shouldRender && renderThread != nil,
                renderSettings: state.renderSettings,
                renderSceneOverride: renderSceneOverride
            )
        }
        guard let request, let simulationThread else { return }

        timings.withLock { $0.beginFrame(request.frameIndex) }
        simulationThread.submit(request)
    }

    public func queueRenderSettings(_ settings: RenderSettings) {
        state.withLock { state in
            state.renderSettings = settings
        }
    }

    public func currentRenderStats() -> RenderFrameStats {
        state.withLock { $0.renderStats }
    }

    public func currentViewportSurfaceState() -> ViewportSurfaceState {
        state.withLock { $0.viewportSurfaceState }
    }

    public func shutdown() {
        let shouldShutdown = state.withLock { state -> Bool in
            guard state.started else { return false }
            state.started = false
            return true
        }
        guard shouldShutdown else { return }

        simulationThread?.shutdown()
        renderThread?.shutdown()
        simulationThread = nil
        renderThread = nil
        ringBuffer = nil

        kernel.withLock { $0.shutdown() }
        do {
            try wgpuBackend.shutdown()
        } catch {
            // Do not crash process during teardown.
        }
        runtime.shutdown()
    }

    deinit {
        shutdown()
    }

    private func handleSimulationFrame(_ report: SimulationFrameReport) {
        timings.withLock { ledger in
            ledger.updateSimulation(report)
        }
    }

    private func handleRenderedFrame(_ report: RenderThreadReport) {
        timings.withLock { ledger in
            ledger.completeRender(report)
        }
        state.withLock { state in
            state.renderStats = report.stats
            state.viewportSurfaceState = report.viewportSurfaceState
        }
    }
}

public struct EngineKernelCoordinator: EngineKernel {
    private var lastFrameIndex: UInt64 = 0

    public init() {}

    public mutating func boot() {}

    public mutating func tick(
        phase: EngineKernelPhase,
        context: EngineKernelPhaseContext
    ) -> EngineKernelFrameReport {
        lastFrameIndex = max(lastFrameIndex, context.frameIndex)
        return EngineKernelFrameReport(
            frameIndex: context.frameIndex,
            phase: phase,
            phaseCount: EngineKernelPhase.allCases.count,
            inputEventCount: context.inputEvents.count
        )
    }

    public mutating func shutdown() {}
}

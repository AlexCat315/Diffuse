import Foundation
import EngineKernel
import RHIWGPU
import SceneRuntime
import AssetPipeline
import ScriptRuntime

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

public protocol EngineRuntime {
    func initialize()
    func tickInput(deltaTime: Double)
    func tickSimulation(deltaTime: Double)
    func tickRenderPrepare(deltaTime: Double)
    func tickRenderSubmit(deltaTime: Double)
    func shutdown()
}

public final class EngineHost {
    private let runtime: any EngineRuntime
    private var kernel: EngineKernelCoordinator
    public let wgpuBackend: WGPUBackend
    private var sceneRuntime: SceneRuntime
    private var scriptRuntime: ScriptRuntime
    private var assetPipeline: AssetPipeline

    public private(set) var lastTimings: PhaseTimings = .init()
    public private(set) var currentInputEvents: [InputEvent] = []

    public init(runtime: any EngineRuntime, wgpuBackend: WGPUBackend = WGPUBackend()) {
        self.runtime = runtime
        self.kernel = EngineKernelCoordinator()
        self.wgpuBackend = wgpuBackend
        self.sceneRuntime = SceneRuntime()
        self.scriptRuntime = ScriptRuntime()
        self.assetPipeline = AssetPipeline()
    }

    public func start() {
        runtime.initialize()
        kernel.boot()
        do {
            try wgpuBackend.initialize()
        } catch {
            fputs("[EngineHost] WGPU backend initialization failed: \(error)\n", stderr)
        }
    }

    public func tick(deltaTime: Double, inputEvents: [InputEvent] = []) {
        self.currentInputEvents = inputEvents
        var timings = PhaseTimings()

        var begin = CFAbsoluteTimeGetCurrent()
        runtime.tickInput(deltaTime: deltaTime)
        timings.inputSeconds = CFAbsoluteTimeGetCurrent() - begin

        begin = CFAbsoluteTimeGetCurrent()
        runtime.tickSimulation(deltaTime: deltaTime)
        sceneRuntime.tick()
        scriptRuntime.tick(deltaTime: deltaTime)
        timings.simulationSeconds = CFAbsoluteTimeGetCurrent() - begin

        begin = CFAbsoluteTimeGetCurrent()
        runtime.tickRenderPrepare(deltaTime: deltaTime)
        _ = assetPipeline.validatePath("Content")
        timings.renderPrepareSeconds = CFAbsoluteTimeGetCurrent() - begin

        begin = CFAbsoluteTimeGetCurrent()
        runtime.tickRenderSubmit(deltaTime: deltaTime)
        _ = kernel.tick(deltaTime: deltaTime)
        timings.renderSubmitSeconds = CFAbsoluteTimeGetCurrent() - begin

        lastTimings = timings
    }

    deinit {
        var localKernel = kernel
        localKernel.shutdown()
        do {
            try wgpuBackend.shutdown()
        } catch {
            // Do not crash process during teardown.
        }
        runtime.shutdown()
    }
}

public struct EngineKernelCoordinator: EngineKernel {
    private var frameIndex: UInt64 = 0

    public init() {}

    public mutating func boot() {}

    public mutating func tick(deltaTime: Double) -> EngineKernelFrameReport {
        _ = deltaTime
        frameIndex += 1
        return EngineKernelFrameReport(frameIndex: frameIndex, phaseCount: EngineKernelPhase.allCases.count)
    }

    public mutating func shutdown() {}
}

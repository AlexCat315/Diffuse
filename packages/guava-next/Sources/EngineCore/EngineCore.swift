import Foundation

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
    public private(set) var lastTimings: PhaseTimings = .init()

    public init(runtime: any EngineRuntime) {
        self.runtime = runtime
    }

    public func start() {
        runtime.initialize()
    }

    public func tick(deltaTime: Double) {
        var timings = PhaseTimings()

        var begin = CFAbsoluteTimeGetCurrent()
        runtime.tickInput(deltaTime: deltaTime)
        timings.inputSeconds = CFAbsoluteTimeGetCurrent() - begin

        begin = CFAbsoluteTimeGetCurrent()
        runtime.tickSimulation(deltaTime: deltaTime)
        timings.simulationSeconds = CFAbsoluteTimeGetCurrent() - begin

        begin = CFAbsoluteTimeGetCurrent()
        runtime.tickRenderPrepare(deltaTime: deltaTime)
        timings.renderPrepareSeconds = CFAbsoluteTimeGetCurrent() - begin

        begin = CFAbsoluteTimeGetCurrent()
        runtime.tickRenderSubmit(deltaTime: deltaTime)
        timings.renderSubmitSeconds = CFAbsoluteTimeGetCurrent() - begin

        lastTimings = timings
    }

    deinit {
        runtime.shutdown()
    }
}

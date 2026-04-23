public enum EngineKernelPhase: CaseIterable, Sendable {
    case boot
    case input
    case simulation
    case script
    case renderPrepare
    case renderSubmit
}

public struct EngineKernelPhaseContext: Sendable {
    public var frameIndex: UInt64
    public var deltaTime: Double
    public var inputEvents: [InputEvent]

    public init(
        frameIndex: UInt64 = 0,
        deltaTime: Double = 0,
        inputEvents: [InputEvent] = []
    ) {
        self.frameIndex = frameIndex
        self.deltaTime = deltaTime
        self.inputEvents = inputEvents
    }
}

public struct EngineKernelFrameReport: Sendable {
    public var frameIndex: UInt64
    public var phase: EngineKernelPhase
    public var phaseCount: Int
    public var inputEventCount: Int

    public init(
        frameIndex: UInt64,
        phase: EngineKernelPhase,
        phaseCount: Int,
        inputEventCount: Int = 0
    ) {
        self.frameIndex = frameIndex
        self.phase = phase
        self.phaseCount = phaseCount
        self.inputEventCount = inputEventCount
    }
}

public protocol EngineKernel: Sendable {
    mutating func boot()
    mutating func tick(phase: EngineKernelPhase, context: EngineKernelPhaseContext) -> EngineKernelFrameReport
    mutating func shutdown()
}

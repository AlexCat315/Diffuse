public enum EngineKernelPhase: CaseIterable, Sendable {
    case boot
    case input
    case simulation
    case script
    case renderPrepare
    case renderSubmit
}

public struct EngineKernelFrameReport: Sendable {
    public var frameIndex: UInt64
    public var phaseCount: Int

    public init(frameIndex: UInt64, phaseCount: Int) {
        self.frameIndex = frameIndex
        self.phaseCount = phaseCount
    }
}

public protocol EngineKernel: Sendable {
    mutating func boot()
    mutating func tick(deltaTime: Double) -> EngineKernelFrameReport
    mutating func shutdown()
}

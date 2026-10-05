import Foundation
import SIMDCompat

public struct PhysicsReplayMismatch: Sendable, Equatable {
    public var frameIndex: Int
    public var expectedSimulatedStep: Int
    public var actualSimulatedStep: Int
    public var expectedStateHash: UInt64
    public var actualStateHash: UInt64

    public init(
        frameIndex: Int,
        expectedSimulatedStep: Int,
        actualSimulatedStep: Int,
        expectedStateHash: UInt64,
        actualStateHash: UInt64
    ) {
        self.frameIndex = frameIndex
        self.expectedSimulatedStep = expectedSimulatedStep
        self.actualSimulatedStep = actualSimulatedStep
        self.expectedStateHash = expectedStateHash
        self.actualStateHash = actualStateHash
    }
}

public struct PhysicsReplayReport: Sendable, Equatable {
    public var replayedFrameCount: Int
    public var checkpointHashes: [UInt64]
    public var mismatches: [PhysicsReplayMismatch]

    public init(
        replayedFrameCount: Int = 0,
        checkpointHashes: [UInt64] = [],
        mismatches: [PhysicsReplayMismatch] = []
    ) {
        self.replayedFrameCount = replayedFrameCount
        self.checkpointHashes = checkpointHashes
        self.mismatches = mismatches
    }

    public var isDeterministic: Bool { mismatches.isEmpty }
}

struct PhysicsCommandReplayControlResource: Sendable, Equatable {
    var isReplaying: Bool = false
}

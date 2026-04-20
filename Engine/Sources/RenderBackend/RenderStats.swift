import Foundation

public struct RenderFrameStats: Sendable {
    public var frameIndex: Int
    public var passCount: Int
    public var drawCallCount: Int
    public var activePasses: [RenderPassKind]
    public var settingsGeneration: UInt64

    public init(
        frameIndex: Int = -1,
        passCount: Int = 0,
        drawCallCount: Int = 0,
        activePasses: [RenderPassKind] = [],
        settingsGeneration: UInt64 = 0
    ) {
        self.frameIndex = frameIndex
        self.passCount = passCount
        self.drawCallCount = drawCallCount
        self.activePasses = activePasses
        self.settingsGeneration = settingsGeneration
    }
}

import Foundation

public struct RenderFrameStats: Sendable {
    public var frameIndex: Int
    public var passCount: Int
    public var drawCallCount: Int
    public var passDrawCallCounts: [RenderPassKind: Int]
    public var renderBundleCount: Int
    public var renderBundleParallelJobs: Int
    public var shadowedLightCount: Int
    public var shadowMapResolution: UInt32
    public var activePasses: [RenderPassKind]
    public var settingsGeneration: UInt64
    public var cpuPrepareNS: UInt64
    public var cpuEncodeNS: UInt64
    public var cpuSubmitNS: UInt64
    public var cpuFrameTotalNS: UInt64
    public var cpuSkyboxEncodeNS: UInt64
    public var cpuBaseEncodeNS: UInt64
    public var cpuPostProcessEncodeNS: UInt64
    public var passEncodeNS: [RenderPassKind: UInt64]

    public init(
        frameIndex: Int = -1,
        passCount: Int = 0,
        drawCallCount: Int = 0,
        passDrawCallCounts: [RenderPassKind: Int] = [:],
        renderBundleCount: Int = 0,
        renderBundleParallelJobs: Int = 0,
        shadowedLightCount: Int = 0,
        shadowMapResolution: UInt32 = 0,
        activePasses: [RenderPassKind] = [],
        settingsGeneration: UInt64 = 0,
        cpuPrepareNS: UInt64 = 0,
        cpuEncodeNS: UInt64 = 0,
        cpuSubmitNS: UInt64 = 0,
        cpuFrameTotalNS: UInt64 = 0,
        cpuSkyboxEncodeNS: UInt64 = 0,
        cpuBaseEncodeNS: UInt64 = 0,
        cpuPostProcessEncodeNS: UInt64 = 0,
        passEncodeNS: [RenderPassKind: UInt64] = [:]
    ) {
        self.frameIndex = frameIndex
        self.passCount = passCount
        self.drawCallCount = drawCallCount
        self.passDrawCallCounts = passDrawCallCounts
        self.renderBundleCount = renderBundleCount
        self.renderBundleParallelJobs = renderBundleParallelJobs
        self.shadowedLightCount = shadowedLightCount
        self.shadowMapResolution = shadowMapResolution
        self.activePasses = activePasses
        self.settingsGeneration = settingsGeneration
        self.cpuPrepareNS = cpuPrepareNS
        self.cpuEncodeNS = cpuEncodeNS
        self.cpuSubmitNS = cpuSubmitNS
        self.cpuFrameTotalNS = cpuFrameTotalNS
        self.cpuSkyboxEncodeNS = cpuSkyboxEncodeNS
        self.cpuBaseEncodeNS = cpuBaseEncodeNS
        self.cpuPostProcessEncodeNS = cpuPostProcessEncodeNS
        self.passEncodeNS = passEncodeNS
    }
}

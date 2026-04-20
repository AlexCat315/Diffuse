import Foundation

public struct RenderSettings: Sendable, Equatable {
    public enum ReplacementStage: Int, Sendable, CaseIterable {
        case r0RainbowTriangle = 0
        case r1MeshCamera = 1
        case r2MultiObjectDepth = 2
        case r3ViewportInterop = 3
        case r4LightingPBRShadow = 4
        case r5PostProcess = 5
    }

    public var stage: ReplacementStage
    public var enableFXAA: Bool
    public var enableSSAO: Bool
    public var enableBloom: Bool
    public var enableShadows: Bool
    public var enableOffscreenViewport: Bool

    public init(
        stage: ReplacementStage = .r1MeshCamera,
        enableFXAA: Bool = false,
        enableSSAO: Bool = false,
        enableBloom: Bool = false,
        enableShadows: Bool = false,
        enableOffscreenViewport: Bool = false
    ) {
        self.stage = stage
        self.enableFXAA = enableFXAA
        self.enableSSAO = enableSSAO
        self.enableBloom = enableBloom
        self.enableShadows = enableShadows
        self.enableOffscreenViewport = enableOffscreenViewport
    }
}

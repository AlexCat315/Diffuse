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
    public var enableSSR: Bool
    public var enableTAA: Bool
    public var enableBloom: Bool
    public var enableRenderBundles: Bool
    public var enableGroupedDrawByMesh: Bool
    public var renderBundleChunkSize: Int
    public var enableShadows: Bool
    public var enableOffscreenViewport: Bool

    public init(
        stage: ReplacementStage = .r1MeshCamera,
        enableFXAA: Bool = false,
        enableSSAO: Bool = false,
        enableSSR: Bool = false,
        enableTAA: Bool = false,
        enableBloom: Bool = false,
        enableRenderBundles: Bool = false,
        enableGroupedDrawByMesh: Bool = false,
        renderBundleChunkSize: Int = 0,
        enableShadows: Bool = false,
        enableOffscreenViewport: Bool = false
    ) {
        self.stage = stage
        self.enableFXAA = enableFXAA
        self.enableSSAO = enableSSAO
        self.enableSSR = enableSSR
        self.enableTAA = enableTAA
        self.enableBloom = enableBloom
        self.enableRenderBundles = enableRenderBundles
        self.enableGroupedDrawByMesh = enableGroupedDrawByMesh
        self.renderBundleChunkSize = max(renderBundleChunkSize, 0)
        self.enableShadows = enableShadows
        self.enableOffscreenViewport = enableOffscreenViewport
    }
}

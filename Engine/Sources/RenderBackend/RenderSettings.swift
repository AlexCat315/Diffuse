import Foundation
import simd

public struct StylizedCharacterStyle: Sendable, Equatable {
    public var toonThresholds: SIMD4<Float>
    public var toonLevels: SIMD4<Float>
    public var inkWashColor: SIMD4<Float>
    public var paperGrainStrength: Float
    public var rimStrength: Float
    public var materialBiasStrength: Float
    public var outlineWidth: Float

    public init(toonThresholds: SIMD4<Float> = SIMD4<Float>(0.24, 0.58, 0.0, 0.0),
                toonLevels: SIMD4<Float> = SIMD4<Float>(0.30, 0.58, 1.0, 0.0),
                inkWashColor: SIMD4<Float> = SIMD4<Float>(0.92, 0.88, 0.78, 1.0),
                paperGrainStrength: Float = 0.035,
                rimStrength: Float = 0.18,
                materialBiasStrength: Float = 0.08,
                outlineWidth: Float = 0.015) {
        self.toonThresholds = toonThresholds
        self.toonLevels = toonLevels
        self.inkWashColor = inkWashColor
        self.paperGrainStrength = paperGrainStrength
        self.rimStrength = rimStrength
        self.materialBiasStrength = materialBiasStrength
        self.outlineWidth = outlineWidth
    }

    public static let colorfulInkCard = StylizedCharacterStyle()
}

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
    public var enableStylizedCharacterShading: Bool
    public var stylizedCharacterStyle: StylizedCharacterStyle

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
        enableOffscreenViewport: Bool = false,
        enableStylizedCharacterShading: Bool = false,
        stylizedCharacterStyle: StylizedCharacterStyle = .colorfulInkCard
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
        self.enableStylizedCharacterShading = enableStylizedCharacterShading
        self.stylizedCharacterStyle = stylizedCharacterStyle
    }
}

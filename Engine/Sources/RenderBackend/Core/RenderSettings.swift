import Foundation
import SIMDCompat

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

public struct RenderShadowSettings: Sendable, Equatable {
    public enum DirectionalLightSelection: String, Sendable, Equatable, CaseIterable {
        case brightest
    }

    public var enabled: Bool
    public var mapResolution: UInt32
    public var depthBias: Float
    public var strength: Float
    public var maxShadowedDirectionalLights: Int
    public var directionalCascadeCount: Int
    public var directionalCascadeSplitLambda: Float
    public var directionalLightSelection: DirectionalLightSelection

    public init(
        enabled: Bool = false,
        mapResolution: UInt32 = 1024,
        depthBias: Float = 0.006,
        strength: Float = 0.62,
        maxShadowedDirectionalLights: Int = 1,
        directionalCascadeCount: Int = 1,
        directionalCascadeSplitLambda: Float = 0.55,
        directionalLightSelection: DirectionalLightSelection = .brightest
    ) {
        self.enabled = enabled
        self.mapResolution = Self.sanitizedMapResolution(mapResolution)
        self.depthBias = max(depthBias, 0)
        self.strength = min(max(strength, 0), 1)
        self.maxShadowedDirectionalLights = max(0, maxShadowedDirectionalLights)
        self.directionalCascadeCount = Self.sanitizedDirectionalCascadeCount(directionalCascadeCount)
        self.directionalCascadeSplitLambda = min(max(directionalCascadeSplitLambda, 0), 1)
        self.directionalLightSelection = directionalLightSelection
    }

    public static let disabled = RenderShadowSettings()
    public static let directionalPreview = RenderShadowSettings(enabled: true)

    public static func sanitizedMapResolution(_ value: UInt32) -> UInt32 {
        min(max(value, 128), 4096)
    }

    public static func sanitizedDirectionalCascadeCount(_ value: Int) -> Int {
        min(max(value, 1), 4)
    }
}

public struct RenderSettings: Sendable, Equatable {
    /// Viewport debug visualization (editor "view mode"). `.shaded` is the normal
    /// PBR result; the rest are G-buffer inspection modes like UE/Godot/Unity.
    /// The raw value is forwarded to the mesh shader via `exposure_light_count.z`.
    public enum DebugViewMode: Int, Sendable, Equatable, CaseIterable {
        case shaded = 0
        case unlit = 1
        case baseColor = 2
        case worldNormal = 3
        case roughness = 4
        case metallic = 5
    }

    public struct Shading: Sendable, Equatable {
        public var pbr = true
        public var depthPrepass = true
        public var debugViewMode = DebugViewMode.shaded
        public init() {}
    }

    public struct PostProcessing: Sendable, Equatable {
        public var fxaa = false
        public var ssao = false
        public var ssr = false
        public var taa = false
        public var bloom = false
        public init() {}
    }

    public struct Visibility: Sendable, Equatable {
        public var frustumCulling = true
        public var meshInstancing = true
        public var distanceLOD = true
        public var groupedDrawByMesh = false
        public init() {}
    }

    public struct Viewport: Sendable, Equatable {
        public enum Backdrop: Sendable, Equatable { case sky, studio }
        public var offscreen = false
        public var backdrop: Backdrop = .sky
        public var gridEnabled = false
        public var gridSpacing: Float = 1
        public init() {}
        mutating func normalize() {
            if !gridSpacing.isFinite || gridSpacing <= 0 { gridSpacing = 1 }
        }
    }

    public struct Stylization: Sendable, Equatable {
        public var enabled = false
        public var style = StylizedCharacterStyle.colorfulInkCard
        public init() {}
    }

    public var shading = Shading()
    public var postProcessing = PostProcessing()
    public var visibility = Visibility()
    public var viewport = Viewport()
    public var shadows = RenderShadowSettings()
    public var stylization = Stylization()

    public init(configure: (inout Self) -> Void = { _ in }) {
        configure(&self)
        viewport.normalize()
    }
}

import simd

public struct RenderMeshComponent: RuntimeComponent, Sendable, Equatable {
    public var meshIndex: Int
    public var isVisible: Bool
    public var colorTint: SIMD3<Float>
    public var assetID: String?

    public init(meshIndex: Int,
                isVisible: Bool = true,
                colorTint: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                assetID: String? = nil) {
        self.meshIndex = meshIndex
        self.isVisible = isVisible
        self.colorTint = colorTint
        self.assetID = assetID
    }
}

public struct RenderMaterialComponent: RuntimeComponent, Sendable, Equatable {
    public var baseColorFactor: SIMD4<Float>
    public var baseColorTextureIndex: Int?
    public var normalTextureIndex: Int?
    public var metallicFactor: Float
    public var roughnessFactor: Float
    public var emissiveFactor: SIMD3<Float>

    public init(baseColorFactor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
                baseColorTextureIndex: Int? = nil,
                normalTextureIndex: Int? = nil,
                metallicFactor: Float = 0,
                roughnessFactor: Float = 1,
                emissiveFactor: SIMD3<Float> = .zero) {
        let material = RenderMaterial(baseColorFactor: baseColorFactor,
                                      baseColorTextureIndex: baseColorTextureIndex,
                                      normalTextureIndex: normalTextureIndex,
                                      metallicFactor: metallicFactor,
                                      roughnessFactor: roughnessFactor,
                                      emissiveFactor: emissiveFactor)
        self.baseColorFactor = material.baseColorFactor
        self.baseColorTextureIndex = material.baseColorTextureIndex
        self.normalTextureIndex = material.normalTextureIndex
        self.metallicFactor = material.metallicFactor
        self.roughnessFactor = material.roughnessFactor
        self.emissiveFactor = material.emissiveFactor
    }

    public var renderMaterial: RenderMaterial {
        RenderMaterial(baseColorFactor: baseColorFactor,
                       baseColorTextureIndex: baseColorTextureIndex,
                       normalTextureIndex: normalTextureIndex,
                       metallicFactor: metallicFactor,
                       roughnessFactor: roughnessFactor,
                       emissiveFactor: emissiveFactor)
    }
}

public struct CameraComponent: RuntimeComponent, Sendable, Equatable {
    public var target: SIMD3<Float>
    public var up: SIMD3<Float>
    public var fovYRadians: Float
    public var near: Float
    public var far: Float
    public var isActive: Bool

    public init(target: SIMD3<Float> = .zero,
                up: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
                fovYRadians: Float = .pi / 4,
                near: Float = 0.1,
                far: Float = 100.0,
                isActive: Bool = true) {
        self.target = target
        self.up = up
        self.fovYRadians = fovYRadians
        self.near = near
        self.far = far
        self.isActive = isActive
    }
}

public enum LightType: String, RuntimeComponent, CaseIterable, Sendable, Equatable {
    case directional
    case point
    case spot
}

public struct LightComponent: RuntimeComponent, Sendable, Equatable {
    public var type: LightType
    public var color: SIMD3<Float>
    public var intensity: Float
    public var range: Float
    public var spotInnerAngleDegrees: Float
    public var spotOuterAngleDegrees: Float

    public init(type: LightType = .directional,
                color: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                intensity: Float = 1.0,
                range: Float = 10.0,
                spotInnerAngleDegrees: Float = 20.0,
                spotOuterAngleDegrees: Float = 30.0) {
        self.type = type
        self.color = color
        self.intensity = intensity
        self.range = max(0, range)
        let outer = max(1, min(179, spotOuterAngleDegrees))
        let inner = max(0, min(outer, spotInnerAngleDegrees))
        self.spotInnerAngleDegrees = inner
        self.spotOuterAngleDegrees = outer
    }
}

public struct ExtractedRenderSceneResource: Sendable {
    public var scene: RenderScene
    public var activeCameraEntity: EntityID?
    public var instanceEntities: [EntityID]
    public var lightEntities: [EntityID]
    public var sourceRevision: UInt64

    public init(scene: RenderScene = .empty,
                activeCameraEntity: EntityID? = nil,
                instanceEntities: [EntityID] = [],
                lightEntities: [EntityID] = [],
                sourceRevision: UInt64 = 0) {
        self.scene = scene
        self.activeCameraEntity = activeCameraEntity
        self.instanceEntities = instanceEntities
        self.lightEntities = lightEntities
        self.sourceRevision = sourceRevision
    }
}

public extension RenderCamera {
    static let fallbackPerspective = RenderCamera(
        eye: SIMD3<Float>(0, 2.4, 7.5),
        target: .zero
    )
}

public extension RenderScene {
    static let empty = RenderScene(camera: .fallbackPerspective)
}

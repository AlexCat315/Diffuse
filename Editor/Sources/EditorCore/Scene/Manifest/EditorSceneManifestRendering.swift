import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestAssetReference: Codable, Sendable, Equatable {
    public let assetID: String
    public let name: String
    public let relativePath: String
    public let absolutePath: String
    public let kind: String
    public let meshIndex: Int

    public init(assetID: String,
                name: String,
                relativePath: String,
                absolutePath: String,
                kind: String,
                meshIndex: Int) {
        self.assetID = assetID
        self.name = name
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.kind = kind
        self.meshIndex = meshIndex
    }

    public init(_ component: AssetReferenceComponent) {
        self.init(assetID: component.assetID,
                  name: component.name,
                  relativePath: component.relativePath,
                  absolutePath: component.absolutePath,
                  kind: component.kind,
                  meshIndex: component.meshIndex)
    }

    var component: AssetReferenceComponent {
        AssetReferenceComponent(assetID: assetID,
                                name: name,
                                relativePath: relativePath,
                                absolutePath: absolutePath,
                                kind: kind,
                                meshIndex: meshIndex)
    }
}

public struct EditorSceneManifestRenderMesh: Codable, Sendable, Equatable {
    public let meshIndex: Int
    public let isVisible: Bool
    public let colorTint: EditorSceneManifestVector3?
    public let assetID: String?
    public let levelsOfDetail: [RenderMeshLOD]?

    public init(meshIndex: Int,
                isVisible: Bool,
                colorTint: EditorSceneManifestVector3? = nil,
                assetID: String? = nil,
                levelsOfDetail: [RenderMeshLOD]? = nil) {
        self.meshIndex = meshIndex
        self.isVisible = isVisible
        self.colorTint = colorTint
        self.assetID = assetID
        self.levelsOfDetail = levelsOfDetail
    }

    public init(_ component: RenderMeshComponent) {
        self.init(meshIndex: component.meshIndex,
                  isVisible: component.isVisible,
                  colorTint: EditorSceneManifestVector3(component.colorTint),
                  assetID: component.assetID,
                  levelsOfDetail: component.levelsOfDetail.isEmpty ? nil : component.levelsOfDetail)
    }

    var component: RenderMeshComponent {
        RenderMeshComponent(meshIndex: meshIndex,
                            isVisible: isVisible,
                            colorTint: colorTint?.simdValue ?? SIMD3<Float>(1, 1, 1),
                            assetID: assetID,
                            levelsOfDetail: levelsOfDetail ?? [])
    }
}

public struct EditorSceneManifestRenderMaterial: Codable, Sendable, Equatable {
    public let baseColorFactor: EditorSceneManifestVector4
    public let baseColorTextureIndex: Int?
    public let normalTextureIndex: Int?
    public let metallicFactor: Float
    public let roughnessFactor: Float
    public let emissiveFactor: EditorSceneManifestVector3
    public let alphaMode: MaterialAlphaMode?
    public let alphaCutoff: Float?
    public let doubleSided: Bool?

    public init(baseColorFactor: EditorSceneManifestVector4,
                baseColorTextureIndex: Int? = nil,
                normalTextureIndex: Int? = nil,
                metallicFactor: Float,
                roughnessFactor: Float,
                emissiveFactor: EditorSceneManifestVector3,
                alphaMode: MaterialAlphaMode? = nil,
                alphaCutoff: Float? = nil,
                doubleSided: Bool? = nil) {
        self.baseColorFactor = baseColorFactor
        self.baseColorTextureIndex = baseColorTextureIndex
        self.normalTextureIndex = normalTextureIndex
        self.metallicFactor = metallicFactor
        self.roughnessFactor = roughnessFactor
        self.emissiveFactor = emissiveFactor
        self.alphaMode = alphaMode
        self.alphaCutoff = alphaCutoff
        self.doubleSided = doubleSided
    }

    public init(_ component: RenderMaterialComponent) {
        self.init(baseColorFactor: EditorSceneManifestVector4(component.baseColorFactor),
                  baseColorTextureIndex: component.baseColorTextureIndex,
                  normalTextureIndex: component.normalTextureIndex,
                  metallicFactor: component.metallicFactor,
                  roughnessFactor: component.roughnessFactor,
                  emissiveFactor: EditorSceneManifestVector3(component.emissiveFactor),
                  alphaMode: component.alphaMode, alphaCutoff: component.alphaCutoff, doubleSided: component.doubleSided)
    }

    var component: RenderMaterialComponent {
        RenderMaterialComponent(baseColorFactor: baseColorFactor.simdValue,
                                baseColorTextureIndex: baseColorTextureIndex,
                                normalTextureIndex: normalTextureIndex,
                                metallicFactor: metallicFactor,
                                roughnessFactor: roughnessFactor,
                                emissiveFactor: emissiveFactor.simdValue,
                                alphaMode: alphaMode, alphaCutoff: alphaCutoff, doubleSided: doubleSided)
    }
}

public struct EditorSceneManifestCamera: Codable, Sendable, Equatable {
    public let target: EditorSceneManifestVector3
    public let up: EditorSceneManifestVector3
    public let fovYRadians: Float
    public let aspectRatio: Float
    public let near: Float
    public let far: Float
    public let isActive: Bool

    private enum CodingKeys: String, CodingKey {
        case target
        case up
        case fovYRadians
        case aspectRatio
        case near
        case far
        case isActive
    }

    public init(target: EditorSceneManifestVector3,
                up: EditorSceneManifestVector3,
                fovYRadians: Float,
                aspectRatio: Float = 1,
                near: Float,
                far: Float,
                isActive: Bool) {
        self.target = target
        self.up = up
        self.fovYRadians = fovYRadians
        self.aspectRatio = max(0.001, aspectRatio)
        self.near = near
        self.far = far
        self.isActive = isActive
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(target: try c.decode(EditorSceneManifestVector3.self, forKey: .target),
                  up: try c.decode(EditorSceneManifestVector3.self, forKey: .up),
                  fovYRadians: try c.decode(Float.self, forKey: .fovYRadians),
                  aspectRatio: try c.decodeIfPresent(Float.self, forKey: .aspectRatio) ?? 1,
                  near: try c.decode(Float.self, forKey: .near),
                  far: try c.decode(Float.self, forKey: .far),
                  isActive: try c.decode(Bool.self, forKey: .isActive))
    }

    public init(_ component: CameraComponent) {
        self.init(target: EditorSceneManifestVector3(component.target),
                  up: EditorSceneManifestVector3(component.up),
                  fovYRadians: component.fovYRadians,
                  aspectRatio: component.aspectRatio,
                  near: component.near,
                  far: component.far,
                  isActive: component.isActive)
    }

    var component: CameraComponent {
        CameraComponent(target: target.simdValue,
                        up: up.simdValue,
                        fovYRadians: fovYRadians,
                        aspectRatio: aspectRatio,
                        near: near,
                        far: far,
                        isActive: isActive)
    }
}

public struct EditorSceneManifestLight: Codable, Sendable, Equatable {
    public let type: String
    public let color: EditorSceneManifestVector3
    public let intensity: Float
    public let range: Float
    public let spotInnerAngleDegrees: Float
    public let spotOuterAngleDegrees: Float

    public init(type: String,
                color: EditorSceneManifestVector3,
                intensity: Float,
                range: Float,
                spotInnerAngleDegrees: Float,
                spotOuterAngleDegrees: Float) {
        self.type = type
        self.color = color
        self.intensity = intensity
        self.range = range
        self.spotInnerAngleDegrees = spotInnerAngleDegrees
        self.spotOuterAngleDegrees = spotOuterAngleDegrees
    }

    public init(_ component: LightComponent) {
        self.init(type: component.type.rawValue,
                  color: EditorSceneManifestVector3(component.color),
                  intensity: component.intensity,
                  range: component.range,
                  spotInnerAngleDegrees: component.spotInnerAngleDegrees,
                  spotOuterAngleDegrees: component.spotOuterAngleDegrees)
    }

    var component: LightComponent {
        LightComponent(type: LightType(rawValue: type) ?? .directional,
                       color: color.simdValue,
                       intensity: intensity,
                       range: range,
                       spotInnerAngleDegrees: spotInnerAngleDegrees,
                       spotOuterAngleDegrees: spotOuterAngleDegrees)
    }
}

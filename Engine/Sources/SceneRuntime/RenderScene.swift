import Foundation
import SIMDCompat

/// Renderer-facing scene description extracted from `SceneRuntime`.
/// `RenderScene` is the complete data contract handed from SceneRuntime to
/// RenderBackend: camera, draw instances, lights, material overrides, and the
/// scene environment for one frame.
public struct RenderMeshHandle: Sendable, Equatable {
    public var meshIndex: Int
    public var assetID: String?

    public init(meshIndex: Int, assetID: String? = nil) {
        self.meshIndex = meshIndex
        self.assetID = assetID
    }
}

public struct RenderMaterial: Sendable, Equatable {
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
        self.baseColorFactor = baseColorFactor
        self.baseColorTextureIndex = baseColorTextureIndex
        self.normalTextureIndex = normalTextureIndex
        self.metallicFactor = max(0, min(1, metallicFactor))
        self.roughnessFactor = max(0, min(1, roughnessFactor))
        self.emissiveFactor = emissiveFactor
    }

    public static let fallback = RenderMaterial()
}

public enum RenderLightType: String, Sendable, Equatable {
    case directional
    case point
    case spot
}

public struct RenderLight: Sendable, Equatable {
    public var type: RenderLightType
    public var position: SIMD3<Float>
    public var direction: SIMD3<Float>
    public var color: SIMD3<Float>
    public var intensity: Float
    public var range: Float
    public var spotInnerAngleRadians: Float
    public var spotOuterAngleRadians: Float
    public var entity: EntityID?

    public init(type: RenderLightType = .directional,
                position: SIMD3<Float> = .zero,
                direction: SIMD3<Float> = SIMD3<Float>(0, -1, 0),
                color: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                intensity: Float = 1,
                range: Float = 10,
                spotInnerAngleRadians: Float = .pi / 9,
                spotOuterAngleRadians: Float = .pi / 6,
                entity: EntityID? = nil) {
        self.type = type
        self.position = position
        self.direction = direction
        self.color = color
        self.intensity = max(0, intensity)
        self.range = max(0, range)
        self.spotOuterAngleRadians = max(0.001, min(.pi, spotOuterAngleRadians))
        self.spotInnerAngleRadians = max(0, min(self.spotOuterAngleRadians, spotInnerAngleRadians))
        self.entity = entity
    }
}

public struct RenderEnvironment: Sendable, Equatable {
    public var ambientColor: SIMD3<Float>
    public var ambientIntensity: Float
    public var exposure: Float

    public init(ambientColor: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                ambientIntensity: Float = 0.03,
                exposure: Float = 1) {
        self.ambientColor = ambientColor
        self.ambientIntensity = max(0, ambientIntensity)
        self.exposure = max(0, exposure)
    }

    public static let fallback = RenderEnvironment()
}

/// One `RenderInstance` = one draw call. `meshIndex` references a mesh
/// previously registered with the renderer's mesh table.
public struct RenderInstance: Sendable {
    public var entity: EntityID?
    public var mesh: RenderMeshHandle
    public var transform: simd_float4x4
    public var colorTint: SIMD3<Float>
    public var material: RenderMaterial

    public var meshIndex: Int {
        get { mesh.meshIndex }
        set { mesh.meshIndex = newValue }
    }

    public init(mesh: RenderMeshHandle,
                transform: simd_float4x4,
                colorTint: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                material: RenderMaterial = .fallback,
                entity: EntityID? = nil) {
        self.entity = entity
        self.mesh = mesh
        self.transform = transform
        self.colorTint = colorTint
        self.material = material
    }

    public init(meshIndex: Int,
                transform: simd_float4x4,
                colorTint: SIMD3<Float> = SIMD3<Float>(1, 1, 1),
                material: RenderMaterial = .fallback,
                entity: EntityID? = nil) {
        self.init(mesh: RenderMeshHandle(meshIndex: meshIndex),
                  transform: transform,
                  colorTint: colorTint,
                  material: material,
                  entity: entity)
    }
}

public struct RenderCamera: Sendable {
    public var eye: SIMD3<Float>
    public var target: SIMD3<Float>
    public var up: SIMD3<Float>
    public var fovYRadians: Float
    public var near: Float
    public var far: Float

    public init(eye: SIMD3<Float>,
                target: SIMD3<Float> = .zero,
                up: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
                fovYRadians: Float = .pi / 4,
                near: Float = 0.1,
                far: Float = 100.0) {
        self.eye = eye
        self.target = target
        self.up = up
        self.fovYRadians = fovYRadians
        self.near = near
        self.far = far
    }
}

public struct RenderScene: Sendable {
    public var camera: RenderCamera
    public var instances: [RenderInstance]
    public var lights: [RenderLight]
    public var environment: RenderEnvironment

    public init(camera: RenderCamera,
                instances: [RenderInstance] = [],
                lights: [RenderLight] = [],
                environment: RenderEnvironment = .fallback) {
        self.camera = camera
        self.instances = instances
        self.lights = lights
        self.environment = environment
    }
}

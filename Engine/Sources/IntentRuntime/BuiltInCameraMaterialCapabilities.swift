import CapabilityRuntime
import Foundation
import SceneRuntime
import SIMDCompat

public enum CameraMaterialCapabilityPreparationError: Error, Sendable, Equatable, CustomStringConvertible {
    case coincidentCameraPositionAndTarget
    case invalidCameraUp
    case noMaterialFields
    case materialSnapshotUnavailable(String)

    public var description: String {
        switch self {
        case .coincidentCameraPositionAndTarget:
            return "camera position and target must be different"
        case .invalidCameraUp:
            return "camera_up must be a non-zero vector"
        case .noMaterialFields:
            return "set_material requires at least one material field"
        case let .materialSnapshotUnavailable(reference):
            return "entity '\(reference)' has no usable material preparation snapshot"
        }
    }
}

public struct SetCameraPoseCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.camera])
        public var entity_id: SceneEntityRef

        @AIField(description: "Camera local-space position in metres.")
        public var position: Vec3

        @AIField(description: "World-space point the camera looks at.")
        public var camera_target: Vec3

        @AIField(description: "Optional world-space camera up vector.")
        public var camera_up: Vec3?

        public init() {}
    }

    public static let id = "scene.set_camera_pose"
    public static let title = "Set camera pose"
    public static let description = "Set camera position, look-at target, and optional up vector."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, requiring: .camera, context: context)
        let position = try capabilityVector(input.position, field: "position")
        let target = try capabilityVector(input.camera_target, field: "camera_target")
        guard length_squared(target - position) > 1e-12 else {
            throw CameraMaterialCapabilityPreparationError.coincidentCameraPositionAndTarget
        }
        let up = try input.camera_up.map { try capabilityVector($0, field: "camera_up") }
        if let up, length_squared(up) <= 1e-12 {
            throw CameraMaterialCapabilityPreparationError.invalidCameraUp
        }
        return PreparedCapability(
            operations: [.scene(.setCameraPose(
                entityID: entityID,
                localTransform: LocalTransform(translation: position),
                target: target,
                up: up
            ))],
            preview: CapabilityPreview(summary: "Set camera pose",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetCameraFOVCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.camera])
        public var entity_id: SceneEntityRef

        @ValueRange(min: 1, max: 179)
        public var camera_fov_y: Double

        public init() {}
    }

    public static let id = "scene.set_camera_fov"
    public static let title = "Set camera FOV"
    public static let description = "Set vertical camera field of view in degrees."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, requiring: .camera, context: context)
        return PreparedCapability(
            operations: [.scene(.setCameraFOV(
                entityID: entityID,
                fovYDegrees: try capabilityFloat(input.camera_fov_y, field: "camera_fov_y")
            ))],
            preview: CapabilityPreview(summary: "Set camera field of view",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetCameraAspectRatioCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.camera])
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0.01, max: 100)
        public var camera_aspect_ratio: Double

        public init() {}
    }

    public static let id = "scene.set_camera_aspect_ratio"
    public static let title = "Set camera aspect ratio"
    public static let description = "Set the authored camera width-to-height ratio."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, requiring: .camera, context: context)
        return PreparedCapability(
            operations: [.scene(.setCameraAspectRatio(
                entityID: entityID,
                aspectRatio: try capabilityFloat(
                    input.camera_aspect_ratio,
                    field: "camera_aspect_ratio"
                )
            ))],
            preview: CapabilityPreview(summary: "Set camera aspect ratio",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetCameraActiveCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.camera])
        public var entity_id: SceneEntityRef

        @AIField(description: "Whether this camera is active for rendering.")
        public var camera_is_active: Bool

        public init() {}
    }

    public static let id = "scene.set_camera_active"
    public static let title = "Set camera active"
    public static let description = "Enable or disable this camera as an active render camera."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, requiring: .camera, context: context)
        return PreparedCapability(
            operations: [.scene(.setCameraActive(entityID: entityID,
                                                 isActive: input.camera_is_active))],
            preview: CapabilityPreview(summary: "Set camera active state",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetMaterialCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0, max: 1)
        public var material_base_color: Vec4?

        @ValueRange(min: 0, max: 1)
        public var material_metallic: Double?

        @ValueRange(min: 0, max: 1)
        public var material_roughness: Double?

        @ValueRange(min: 0, max: 1)
        public var material_emissive: Vec3?

        public init() {}
    }

    public static let id = "scene.set_material"
    public static let title = "Set PBR material"
    public static let description = "Update selected PBR material fields while preserving omitted values."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        guard input.material_base_color != nil
                || input.material_metallic != nil
                || input.material_roughness != nil
                || input.material_emissive != nil else {
            throw CameraMaterialCapabilityPreparationError.noMaterialFields
        }
        let entityID = try preparedEntityID(input.entity_id, context: context)
        guard let entity = context.entities.first(where: { $0.reference == input.entity_id.rawValue }) else {
            throw BuiltInCapabilityPreparationError.entityNotFound(input.entity_id.rawValue)
        }
        let snapshot = entity.renderMaterial ?? CapabilityPreparationMaterial(
            baseColor: [1, 1, 1, 1],
            metallic: 0,
            roughness: 1,
            emissive: [0, 0, 0]
        )
        guard let snapshot else {
            throw CameraMaterialCapabilityPreparationError.materialSnapshotUnavailable(
                input.entity_id.rawValue
            )
        }
        var baseColor = SIMD4(snapshot.baseColor[0], snapshot.baseColor[1],
                              snapshot.baseColor[2], snapshot.baseColor[3])
        var metallic = snapshot.metallic
        var roughness = snapshot.roughness
        var emissive = SIMD3(snapshot.emissive[0], snapshot.emissive[1], snapshot.emissive[2])
        if let value = input.material_base_color {
            baseColor = try capabilityVector(value, field: "material_base_color")
        }
        if let value = input.material_metallic {
            metallic = try capabilityFloat(value, field: "material_metallic")
        }
        if let value = input.material_roughness {
            roughness = try capabilityFloat(value, field: "material_roughness")
        }
        if let value = input.material_emissive {
            emissive = try capabilityVector(value, field: "material_emissive")
        }
        return PreparedCapability(
            operations: [.scene(.setRenderMaterialComponent(
                entityID: entityID,
                baseColorFactor: baseColor,
                baseColorTextureIndex: snapshot.baseColorTextureIndex,
                normalTextureIndex: snapshot.normalTextureIndex,
                metallicFactor: metallic,
                roughnessFactor: roughness,
                emissiveFactor: emissive
            ))],
            preview: CapabilityPreview(summary: "Set PBR material",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

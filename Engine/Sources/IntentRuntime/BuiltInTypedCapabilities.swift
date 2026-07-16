import CapabilityRuntime
import Foundation
import SceneRuntime
import SIMDCompat

public enum BuiltInCapabilityPreparationError: Error, Sendable, Equatable, CustomStringConvertible {
    case entityNotFound(String)
    case localTransformUnavailable(String)
    case noTransformFields
    case emptyName
    case missingRequiredComponent(reference: String, component: String)
    case valueOutOfFloatRange(String)
    case noSpotAngleFields
    case invalidSpotAngleOrder

    public var description: String {
        switch self {
        case let .entityNotFound(reference):
            return "entity '\(reference)' is unavailable in the capability preparation snapshot"
        case let .localTransformUnavailable(reference):
            return "entity '\(reference)' has no local transform in the capability preparation snapshot"
        case .noTransformFields:
            return "set_transform requires at least one of position, euler_degrees, or scale"
        case .emptyName:
            return "set_name requires a non-empty name"
        case let .missingRequiredComponent(reference, component):
            return "entity '\(reference)' is missing required component '\(component)'"
        case let .valueOutOfFloatRange(field):
            return "field '\(field)' contains a value outside the engine's finite Float range"
        case .noSpotAngleFields:
            return "set_light_spot_angles requires an inner or outer angle"
        case .invalidSpotAngleOrder:
            return "spot_inner_angle cannot be greater than spot_outer_angle"
        }
    }
}

func preparedEntityID(
    _ reference: SceneEntityRef,
    requiring component: SceneComponentRequirement? = nil,
    context: CapabilityPreparationContext
) throws -> UInt64 {
    guard let entity = context.entities.first(where: { $0.reference == reference.rawValue }),
          let rawID = UInt64(reference.rawValue.dropFirst("scene:".count)) else {
        throw BuiltInCapabilityPreparationError.entityNotFound(reference.rawValue)
    }
    if let component,
       !entity.componentTypes.contains(component.rawValue) {
        throw BuiltInCapabilityPreparationError.missingRequiredComponent(
            reference: reference.rawValue,
            component: component.rawValue
        )
    }
    return rawID
}

func capabilityFloat(_ value: Double, field: String) throws -> Float {
    let converted = Float(value)
    guard converted.isFinite else {
        throw BuiltInCapabilityPreparationError.valueOutOfFloatRange(field)
    }
    return converted
}

func capabilityVector(_ value: Vec3, field: String) throws -> SIMD3<Float> {
    try SIMD3(
        capabilityFloat(value.x, field: field),
        capabilityFloat(value.y, field: field),
        capabilityFloat(value.z, field: field)
    )
}

func capabilityVector(_ value: Vec4, field: String) throws -> SIMD4<Float> {
    try SIMD4(
        capabilityFloat(value.x, field: field),
        capabilityFloat(value.y, field: field),
        capabilityFloat(value.z, field: field),
        capabilityFloat(value.w, field: field)
    )
}

private func preparedLocalTransform(
    _ reference: SceneEntityRef,
    context: CapabilityPreparationContext
) throws -> (entityID: UInt64, transform: LocalTransform) {
    let entityID = try preparedEntityID(reference, context: context)
    guard let snapshot = context.entities.first(where: { $0.reference == reference.rawValue })?.localTransform,
          snapshot.columnMajorMatrix.count == 16 else {
        throw BuiltInCapabilityPreparationError.localTransformUnavailable(reference.rawValue)
    }
    let values = snapshot.columnMajorMatrix
    let matrix = simd_float4x4(columns: (
        SIMD4(values[0], values[1], values[2], values[3]),
        SIMD4(values[4], values[5], values[6], values[7]),
        SIMD4(values[8], values[9], values[10], values[11]),
        SIMD4(values[12], values[13], values[14], values[15])
    ))
    return (entityID, LocalTransform(matrix: matrix))
}

private func transformRotationMatrix(eulerDegrees: SIMD3<Float>) -> simd_float4x4 {
    let toRadians: Float = .pi / 180
    let x = simd_float4x4(simd_quatf(angle: eulerDegrees.x * toRadians, axis: SIMD3(1, 0, 0)))
    let y = simd_float4x4(simd_quatf(angle: eulerDegrees.y * toRadians, axis: SIMD3(0, 1, 0)))
    let z = simd_float4x4(simd_quatf(angle: eulerDegrees.z * toRadians, axis: SIMD3(0, 0, 1)))
    return x * y * z
}

private func transformScale(_ matrix: simd_float4x4) -> SIMD3<Float> {
    SIMD3(
        length(SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)),
        length(SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)),
        length(SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
    )
}

private func transformRotationOnly(_ matrix: simd_float4x4) -> simd_float4x4 {
    let scale = transformScale(matrix)
    let x = scale.x > 1e-6
        ? SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z) / scale.x
        : SIMD3<Float>(1, 0, 0)
    let y = scale.y > 1e-6
        ? SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z) / scale.y
        : SIMD3<Float>(0, 1, 0)
    let z = scale.z > 1e-6
        ? SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z) / scale.z
        : SIMD3<Float>(0, 0, 1)
    return simd_float4x4(columns: (
        SIMD4(x, 0), SIMD4(y, 0), SIMD4(z, 0), SIMD4(0, 0, 0, 1)
    ))
}

private func composedTransformMatrix(
    translation: SIMD3<Float>,
    rotation: simd_float4x4,
    scale: SIMD3<Float>
) -> simd_float4x4 {
    var matrix = rotation
    matrix.columns.0 *= scale.x
    matrix.columns.1 *= scale.y
    matrix.columns.2 *= scale.z
    matrix.columns.3 = SIMD4(translation, 1)
    return matrix
}

/// First migrated host primitives. Each type is the sole declaration of its
/// decoder, JSON Schema, provider/MCP contract, and pure preparation behavior.
public struct SetNameCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @AIField(description: "New entity display name.", minLength: 1, maxLength: 256)
        public var name: String

        public init() {}
    }

    public static let id = "scene.set_name"
    public static let title = "Rename entity"
    public static let description = "Set an entity's display name."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        guard !input.name.isEmpty else {
            throw BuiltInCapabilityPreparationError.emptyName
        }
        let entityID = try preparedEntityID(input.entity_id, context: context)
        return PreparedCapability(
            operations: [.scene(.setSceneName(entityID: entityID, value: input.name))],
            preview: CapabilityPreview(summary: "Rename entity",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct DeleteEntityCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        public init() {}
    }

    public static let id = "scene.delete_entity"
    public static let title = "Delete entity"
    public static let description = "Delete an entity and its authored scene state."
    public static let domain = "scene"
    public static let access = CapabilityAccess.destructiveWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, context: context)
        return PreparedCapability(
            operations: [.scene(.deleteEntity(entityID: entityID))],
            preview: CapabilityPreview(summary: "Delete entity",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.deletedEntity(entityID), .entityIsAbsent(entityID)]
        )
    }
}

public struct DuplicateEntityCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @AIField(description: "Optional local-space offset for the duplicate.")
        public var duplicate_offset: Vec3?

        public init() {}
    }

    public static let id = "scene.duplicate_entity"
    public static let title = "Duplicate entity"
    public static let description = "Duplicate an entity, optionally with a local-space offset."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, context: context)
        let operation: TransactionOperation
        if let offset = input.duplicate_offset {
            operation = .scene(.duplicateEntityWithOffset(
                entityID: entityID,
                positionOffset: try capabilityVector(offset, field: "duplicate_offset")
            ))
        } else {
            operation = .scene(.duplicateEntity(entityID: entityID))
        }
        return PreparedCapability(
            operations: [operation],
            preview: CapabilityPreview(summary: "Duplicate entity",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID), .createdEntityCount(1)]
        )
    }
}

public struct SetTransformCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.localTransform])
        public var entity_id: SceneEntityRef

        @AIField(description: "New local-space position in metres.")
        public var position: Vec3?

        @AIField(description: "XYZ intrinsic Euler rotation in degrees.")
        public var euler_degrees: Vec3?

        @ValueRange(min: 0.001, max: 1_000)
        public var scale: Vec3?

        public init() {}
    }

    public static let id = "scene.set_transform"
    public static let title = "Set transform"
    public static let description = "Set selected local transform fields without overwriting omitted fields."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        guard input.position != nil || input.euler_degrees != nil || input.scale != nil else {
            throw BuiltInCapabilityPreparationError.noTransformFields
        }
        let prepared = try preparedLocalTransform(input.entity_id, context: context)
        var transform = prepared.transform
        if let position = input.position {
            transform.matrix.columns.3 = SIMD4(
                try capabilityVector(position, field: "position"), 1
            )
        }
        if let euler = input.euler_degrees {
            transform.matrix = composedTransformMatrix(
                translation: transform.translation,
                rotation: transformRotationMatrix(
                    eulerDegrees: try capabilityVector(euler, field: "euler_degrees")
                ),
                scale: transformScale(transform.matrix)
            )
        }
        if let scale = input.scale {
            transform.matrix = composedTransformMatrix(
                translation: transform.translation,
                rotation: transformRotationOnly(transform.matrix),
                scale: try capabilityVector(scale, field: "scale")
            )
        }
        return PreparedCapability(
            operations: [.scene(.setLocalTransform(
                entityID: prepared.entityID,
                transform: transform
            ))],
            preview: CapabilityPreview(
                summary: "Set entity transform",
                targetReferences: [input.entity_id.rawValue]
            ),
            assertions: [.entityExists(prepared.entityID)]
        )
    }
}

public enum CapabilityLightType: String, CapabilitySchemaValue, CaseIterable {
    case directional
    case point
    case spot

    public static var capabilitySchema: JSONSchema {
        .string(allowedValues: allCases.map(\.rawValue))
    }

    public static var capabilityPlaceholder: CapabilityLightType { .point }

    fileprivate var runtimeValue: LightType {
        switch self {
        case .directional: return .directional
        case .point: return .point
        case .spot: return .spot
        }
    }
}

public struct SetLightTypeCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.light])
        public var entity_id: SceneEntityRef

        @AIField(description: "New light type.")
        public var light_type: CapabilityLightType

        public init() {}
    }

    public static let id = "scene.set_light_type"
    public static let title = "Set light type"
    public static let description = "Change a light to directional, point, or spot."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, requiring: .light, context: context)
        return PreparedCapability(
            operations: [.scene(.setLightType(entityID: entityID, type: input.light_type.runtimeValue))],
            preview: CapabilityPreview(summary: "Set light type",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetLightIntensityCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.light])
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0)
        public var intensity: Double

        public init() {}
    }

    public static let id = "scene.set_light_intensity"
    public static let title = "Set light intensity"
    public static let description = "Set non-negative light intensity."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, requiring: .light, context: context)
        return PreparedCapability(
            operations: [.scene(.setLightIntensity(
                entityID: entityID,
                intensity: try capabilityFloat(input.intensity, field: "intensity")
            ))],
            preview: CapabilityPreview(summary: "Set light intensity",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetLightColorCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.light])
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0, max: 1)
        public var color: Vec3

        public init() {}
    }

    public static let id = "scene.set_light_color"
    public static let title = "Set light colour"
    public static let description = "Set linear RGB light colour."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, requiring: .light, context: context)
        return PreparedCapability(
            operations: [.scene(.setLightColor(
                entityID: entityID,
                color: try capabilityVector(input.color, field: "color")
            ))],
            preview: CapabilityPreview(summary: "Set light colour",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetLightRangeCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.light])
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0)
        public var range: Double

        public init() {}
    }

    public static let id = "scene.set_light_range"
    public static let title = "Set light range"
    public static let description = "Set non-negative light range in metres."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, requiring: .light, context: context)
        return PreparedCapability(
            operations: [.scene(.setLightRange(
                entityID: entityID,
                range: try capabilityFloat(input.range, field: "range")
            ))],
            preview: CapabilityPreview(summary: "Set light range",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetLightSpotAnglesCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.light])
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0, max: 180)
        public var spot_inner_angle: Double?

        @ValueRange(min: 0, max: 180)
        public var spot_outer_angle: Double?

        public init() {}
    }

    public static let id = "scene.set_light_spot_angles"
    public static let title = "Set spot angles"
    public static let description = "Set the spot light inner and outer cone angles."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        guard input.spot_inner_angle != nil || input.spot_outer_angle != nil else {
            throw BuiltInCapabilityPreparationError.noSpotAngleFields
        }
        if let inner = input.spot_inner_angle,
           let outer = input.spot_outer_angle,
           inner > outer {
            throw BuiltInCapabilityPreparationError.invalidSpotAngleOrder
        }
        let entityID = try preparedEntityID(input.entity_id, requiring: .light, context: context)
        var operations: [TransactionOperation] = []
        if let inner = input.spot_inner_angle {
            operations.append(.scene(.setLightSpotInnerAngle(
                entityID: entityID,
                angleDegrees: try capabilityFloat(inner, field: "spot_inner_angle")
            )))
        }
        if let outer = input.spot_outer_angle {
            operations.append(.scene(.setLightSpotOuterAngle(
                entityID: entityID,
                angleDegrees: try capabilityFloat(outer, field: "spot_outer_angle")
            )))
        }
        return PreparedCapability(
            operations: operations,
            preview: CapabilityPreview(summary: "Set spot light angles",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public struct SetLightCastShadowsCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference(requires: [.light])
        public var entity_id: SceneEntityRef

        @AIField(description: "Whether the light casts shadows.")
        public var light_cast_shadows: Bool

        public init() {}
    }

    public static let id = "scene.set_light_cast_shadows"
    public static let title = "Set light shadows"
    public static let description = "Enable or disable shadow casting for a light."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.stable

    public static func prepare(
        input: Input,
        context: CapabilityPreparationContext
    ) throws -> PreparedCapability {
        let entityID = try preparedEntityID(input.entity_id, requiring: .light, context: context)
        return PreparedCapability(
            operations: [.scene(.setLightCastShadows(
                entityID: entityID,
                value: input.light_cast_shadows
            ))],
            preview: CapabilityPreview(summary: "Set light shadow casting",
                                       targetReferences: [input.entity_id.rawValue]),
            assertions: [.entityExists(entityID)]
        )
    }
}

public enum BuiltInTypedCapabilityCatalog {
    public static let registrations: [AnyCapabilityRegistration] = {
        do {
            return [
                try AnyCapabilityRegistration(SetNameCapability.self),
                try AnyCapabilityRegistration(DeleteEntityCapability.self),
                try AnyCapabilityRegistration(DuplicateEntityCapability.self),
                try AnyCapabilityRegistration(SetTransformCapability.self),
                try AnyCapabilityRegistration(SetLightTypeCapability.self),
                try AnyCapabilityRegistration(SetLightIntensityCapability.self),
                try AnyCapabilityRegistration(SetLightColorCapability.self),
                try AnyCapabilityRegistration(SetLightRangeCapability.self),
                try AnyCapabilityRegistration(SetLightSpotAnglesCapability.self),
                try AnyCapabilityRegistration(SetLightCastShadowsCapability.self),
                try AnyCapabilityRegistration(SetCameraPoseCapability.self),
                try AnyCapabilityRegistration(SetCameraFOVCapability.self),
                try AnyCapabilityRegistration(SetCameraAspectRatioCapability.self),
                try AnyCapabilityRegistration(SetCameraActiveCapability.self),
                try AnyCapabilityRegistration(SetMaterialCapability.self),
                try AnyCapabilityRegistration(SetRigidBodyMotionTypeCapability.self),
                try AnyCapabilityRegistration(SetRigidBodyMassCapability.self),
                try AnyCapabilityRegistration(SetRigidBodyGravityScaleCapability.self),
                try AnyCapabilityRegistration(SetRigidBodyAllowSleepCapability.self),
                try AnyCapabilityRegistration(SetColliderShapeCapability.self),
                try AnyCapabilityRegistration(SetColliderBoxExtentsCapability.self),
                try AnyCapabilityRegistration(SetColliderSphereRadiusCapability.self),
                try AnyCapabilityRegistration(SetColliderCapsuleCapability.self),
                try AnyCapabilityRegistration(SetColliderMaterialCapability.self),
                try AnyCapabilityRegistration(SetColliderTriggerCapability.self),
                try AnyCapabilityRegistration(SetColliderLayerCapability.self),
            ]
        } catch {
            preconditionFailure("invalid built-in capability declaration: \(error)")
        }
    }()

    private static let byID = Dictionary(uniqueKeysWithValues: registrations.map {
        ($0.contract.id, $0)
    })

    public static func registration(for capabilityID: String) -> AnyCapabilityRegistration? {
        byID[capabilityID]
    }

    public static let registry = CapabilityRegistry.default.replacingContracts(
        registrations.map(\.contract)
    )
}

public extension CapabilityRegistry {
    /// Registry used by model-facing paths. Migrated entries are derived from
    /// their typed declarations; non-migrated entries retain compatibility
    /// contracts until their capability types are moved into this catalog.
    static let aiDefault = BuiltInTypedCapabilityCatalog.registry
}

import CapabilityRuntime
import Foundation
import SceneRuntime
import SIMDCompat

public enum PhysicsCapabilityPreparationError: Error, Sendable, Equatable, CustomStringConvertible {
    case noCapsuleFields
    case noMaterialFields
    case noLayerFields

    public var description: String {
        switch self {
        case .noCapsuleFields:
            return "set_collider_capsule requires radius or half_height"
        case .noMaterialFields:
            return "set_collider_material requires friction, restitution, or density"
        case .noLayerFields:
            return "set_collider_layer requires collider_layer_id or collider_layer_mask"
        }
    }
}

private func preparedPhysicsEntity(
    _ reference: SceneEntityRef,
    context: CapabilityPreparationContext
) throws -> (entityID: UInt64, entity: CapabilityPreparationEntity) {
    let entityID = try preparedEntityID(reference, context: context)
    guard let entity = context.entities.first(where: { $0.reference == reference.rawValue }) else {
        throw BuiltInCapabilityPreparationError.entityNotFound(reference.rawValue)
    }
    return (entityID, entity)
}

private func defaultCollider() -> Collider {
    Collider(shape: .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero))
}

public enum CapabilityRigidBodyMotionType: String, CapabilitySchemaValue, CaseIterable {
    case `static`
    case dynamic
    case kinematic

    public static var capabilitySchema: JSONSchema {
        .string(allowedValues: allCases.map(\.rawValue))
    }

    public static var capabilityPlaceholder: CapabilityRigidBodyMotionType { .dynamic }

    fileprivate var runtimeValue: RigidBodyMotionType {
        switch self {
        case .static: return .static
        case .dynamic: return .dynamic
        case .kinematic: return .kinematic
        }
    }
}

public struct SetRigidBodyMotionTypeCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @AIField(description: "Static, dynamic, or kinematic rigid-body motion.")
        public var motion_type: CapabilityRigidBodyMotionType

        public init() {}
    }

    public static let id = "scene.set_rigid_body_motion_type"
    public static let title = "Set rigid body motion"
    public static let description = "Create or update a rigid body with static, dynamic, or kinematic motion."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.beta

    public static func prepare(input: Input,
                               context: CapabilityPreparationContext) throws -> PreparedCapability {
        let prepared = try preparedPhysicsEntity(input.entity_id, context: context)
        var body = prepared.entity.rigidBody ?? RigidBody()
        body.motionType = input.motion_type.runtimeValue
        return physicsPrepared(
            entityID: prepared.entityID,
            reference: input.entity_id,
            summary: "Set rigid body motion",
            mutation: .setRigidBody(entityID: prepared.entityID, body: body)
        )
    }
}

public struct SetRigidBodyMassCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0.0001)
        public var mass: Double

        public init() {}
    }

    public static let id = "scene.set_rigid_body_mass"
    public static let title = "Set rigid body mass"
    public static let description = "Create or update a rigid body's positive mass in kilograms."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.beta

    public static func prepare(input: Input,
                               context: CapabilityPreparationContext) throws -> PreparedCapability {
        let prepared = try preparedPhysicsEntity(input.entity_id, context: context)
        var body = prepared.entity.rigidBody ?? RigidBody()
        body.mass = try capabilityFloat(input.mass, field: "mass")
        return physicsPrepared(
            entityID: prepared.entityID,
            reference: input.entity_id,
            summary: "Set rigid body mass",
            mutation: .setRigidBody(entityID: prepared.entityID, body: body)
        )
    }
}

public struct SetRigidBodyGravityScaleCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @AIField(description: "Multiplier applied to scene gravity.")
        public var gravity_scale: Double

        public init() {}
    }

    public static let id = "scene.set_rigid_body_gravity_scale"
    public static let title = "Set rigid body gravity scale"
    public static let description = "Create or update a rigid body's gravity multiplier."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.beta

    public static func prepare(input: Input,
                               context: CapabilityPreparationContext) throws -> PreparedCapability {
        let prepared = try preparedPhysicsEntity(input.entity_id, context: context)
        var body = prepared.entity.rigidBody ?? RigidBody()
        body.gravityScale = try capabilityFloat(input.gravity_scale, field: "gravity_scale")
        return physicsPrepared(
            entityID: prepared.entityID,
            reference: input.entity_id,
            summary: "Set rigid body gravity scale",
            mutation: .setRigidBody(entityID: prepared.entityID, body: body)
        )
    }
}

public struct SetRigidBodyAllowSleepCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @AIField(description: "Whether the rigid body may enter the sleeping state.")
        public var allow_sleep: Bool

        public init() {}
    }

    public static let id = "scene.set_rigid_body_allow_sleep"
    public static let title = "Set rigid body sleeping"
    public static let description = "Create or update whether a rigid body may sleep."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.beta

    public static func prepare(input: Input,
                               context: CapabilityPreparationContext) throws -> PreparedCapability {
        let prepared = try preparedPhysicsEntity(input.entity_id, context: context)
        var body = prepared.entity.rigidBody ?? RigidBody()
        body.allowSleep = input.allow_sleep
        return physicsPrepared(
            entityID: prepared.entityID,
            reference: input.entity_id,
            summary: "Set rigid body sleeping",
            mutation: .setRigidBody(entityID: prepared.entityID, body: body)
        )
    }
}

public enum CapabilityColliderShape: String, CapabilitySchemaValue, CaseIterable {
    case box
    case sphere
    case capsule
    case cylinder
    case heightField
    case mesh
    case convex

    public static var capabilitySchema: JSONSchema {
        .string(allowedValues: allCases.map(\.rawValue))
    }

    public static var capabilityPlaceholder: CapabilityColliderShape { .box }

    fileprivate var runtimeValue: ColliderShapeKind {
        ColliderShapeKind(rawValue: rawValue) ?? .box
    }
}

public struct SetColliderShapeCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @AIField(description: "Collider shape kind.")
        public var collider_shape: CapabilityColliderShape

        public init() {}
    }

    public static let id = "scene.set_collider_shape"
    public static let title = "Set collider shape"
    public static let description = "Create or update the primary collider shape."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.beta

    public static func prepare(input: Input,
                               context: CapabilityPreparationContext) throws -> PreparedCapability {
        let prepared = try preparedPhysicsEntity(input.entity_id, context: context)
        var collider = prepared.entity.collider ?? defaultCollider()
        switch input.collider_shape.runtimeValue {
        case .box:
            if case let .box(halfExtents, center) = collider.shape {
                collider.shape = .box(halfExtents: halfExtents, center: center)
            } else {
                collider.shape = .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero)
            }
        case .sphere:
            if case let .sphere(radius, center) = collider.shape {
                collider.shape = .sphere(radius: radius, center: center)
            } else {
                collider.shape = .sphere(radius: 0.5, center: .zero)
            }
        case .capsule:
            if case let .capsule(radius, halfHeight, center) = collider.shape {
                collider.shape = .capsule(radius: radius, halfHeight: halfHeight, center: center)
            } else {
                collider.shape = .capsule(radius: 0.25, halfHeight: 0.5, center: .zero)
            }
        case .cylinder:
            if case let .cylinder(radius, halfHeight, center) = collider.shape {
                collider.shape = .cylinder(radius: radius, halfHeight: halfHeight, center: center)
            } else {
                collider.shape = .cylinder(radius: 0.5, halfHeight: 0.5, center: .zero)
            }
        case .heightField:
            if case let .heightField(resourceID, center) = collider.shape {
                collider.shape = .heightField(resourceID: resourceID, center: center)
            } else {
                collider.shape = .heightField(resourceID: nil, center: .zero)
            }
        case .mesh:
            if case let .mesh(resourceID, center) = collider.shape {
                collider.shape = .mesh(resourceID: resourceID, center: center)
            } else {
                collider.shape = .mesh(resourceID: nil, center: .zero)
            }
        case .convex:
            if case let .convex(resourceID, center) = collider.shape {
                collider.shape = .convex(resourceID: resourceID, center: center)
            } else {
                collider.shape = .convex(resourceID: nil, center: .zero)
            }
        }
        return physicsPrepared(
            entityID: prepared.entityID,
            reference: input.entity_id,
            summary: "Set collider shape",
            mutation: .setCollider(entityID: prepared.entityID, collider: collider)
        )
    }
}

public struct SetColliderBoxExtentsCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0.0001)
        public var half_extents: Vec3

        public init() {}
    }

    public static let id = "scene.set_collider_box_extents"
    public static let title = "Set box collider extents"
    public static let description = "Create a box collider or update its positive half extents."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.beta

    public static func prepare(input: Input,
                               context: CapabilityPreparationContext) throws -> PreparedCapability {
        let prepared = try preparedPhysicsEntity(input.entity_id, context: context)
        var collider = prepared.entity.collider ?? defaultCollider()
        let center: SIMD3<Float>
        if case let .box(_, value) = collider.shape { center = value } else { center = .zero }
        collider.shape = .box(
            halfExtents: try capabilityVector(input.half_extents, field: "half_extents"),
            center: center
        )
        return physicsPrepared(entityID: prepared.entityID,
                               reference: input.entity_id,
                               summary: "Set box collider extents",
                               mutation: .setCollider(entityID: prepared.entityID,
                                                      collider: collider))
    }
}

public struct SetColliderSphereRadiusCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0.0001)
        public var radius: Double

        public init() {}
    }

    public static let id = "scene.set_collider_sphere_radius"
    public static let title = "Set sphere collider radius"
    public static let description = "Create a sphere collider or update its positive radius."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.beta

    public static func prepare(input: Input,
                               context: CapabilityPreparationContext) throws -> PreparedCapability {
        let prepared = try preparedPhysicsEntity(input.entity_id, context: context)
        var collider = prepared.entity.collider ?? defaultCollider()
        let center: SIMD3<Float>
        if case let .sphere(_, value) = collider.shape { center = value } else { center = .zero }
        collider.shape = .sphere(radius: try capabilityFloat(input.radius, field: "radius"),
                                 center: center)
        return physicsPrepared(entityID: prepared.entityID,
                               reference: input.entity_id,
                               summary: "Set sphere collider radius",
                               mutation: .setCollider(entityID: prepared.entityID,
                                                      collider: collider))
    }
}

public struct SetColliderCapsuleCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0.0001)
        public var radius: Double?

        @ValueRange(min: 0.0001)
        public var half_height: Double?

        public init() {}
    }

    public static let id = "scene.set_collider_capsule"
    public static let title = "Set capsule collider dimensions"
    public static let description = "Create a capsule collider or update selected positive dimensions."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.beta

    public static func prepare(input: Input,
                               context: CapabilityPreparationContext) throws -> PreparedCapability {
        guard input.radius != nil || input.half_height != nil else {
            throw PhysicsCapabilityPreparationError.noCapsuleFields
        }
        let prepared = try preparedPhysicsEntity(input.entity_id, context: context)
        var collider = prepared.entity.collider ?? defaultCollider()
        var radius: Float = 0.25
        var halfHeight: Float = 0.5
        var center = SIMD3<Float>.zero
        if case let .capsule(oldRadius, oldHalfHeight, oldCenter) = collider.shape {
            radius = oldRadius
            halfHeight = oldHalfHeight
            center = oldCenter
        }
        if let value = input.radius {
            radius = try capabilityFloat(value, field: "radius")
        }
        if let value = input.half_height {
            halfHeight = try capabilityFloat(value, field: "half_height")
        }
        collider.shape = .capsule(radius: radius, halfHeight: halfHeight, center: center)
        return physicsPrepared(entityID: prepared.entityID,
                               reference: input.entity_id,
                               summary: "Set capsule collider dimensions",
                               mutation: .setCollider(entityID: prepared.entityID,
                                                      collider: collider))
    }
}

public struct SetColliderMaterialCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0, max: 1)
        public var friction: Double?

        @ValueRange(min: 0, max: 1)
        public var restitution: Double?

        @ValueRange(min: 0)
        public var density: Double?

        public init() {}
    }

    public static let id = "scene.set_collider_material"
    public static let title = "Set collider material"
    public static let description = "Create or update selected collider material fields."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.beta

    public static func prepare(input: Input,
                               context: CapabilityPreparationContext) throws -> PreparedCapability {
        guard input.friction != nil || input.restitution != nil || input.density != nil else {
            throw PhysicsCapabilityPreparationError.noMaterialFields
        }
        let prepared = try preparedPhysicsEntity(input.entity_id, context: context)
        var collider = prepared.entity.collider ?? defaultCollider()
        if let value = input.friction {
            collider.material.friction = try capabilityFloat(value, field: "friction")
        }
        if let value = input.restitution {
            collider.material.restitution = try capabilityFloat(value, field: "restitution")
        }
        if let value = input.density {
            collider.material.density = try capabilityFloat(value, field: "density")
        }
        return physicsPrepared(entityID: prepared.entityID,
                               reference: input.entity_id,
                               summary: "Set collider material",
                               mutation: .setCollider(entityID: prepared.entityID,
                                                      collider: collider))
    }
}

public struct SetColliderTriggerCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @AIField(description: "Whether the collider behaves as a trigger.")
        public var is_trigger: Bool

        public init() {}
    }

    public static let id = "scene.set_collider_trigger"
    public static let title = "Set collider trigger"
    public static let description = "Create or update collider trigger behaviour."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.beta

    public static func prepare(input: Input,
                               context: CapabilityPreparationContext) throws -> PreparedCapability {
        let prepared = try preparedPhysicsEntity(input.entity_id, context: context)
        var collider = prepared.entity.collider ?? defaultCollider()
        collider.isTrigger = input.is_trigger
        return physicsPrepared(entityID: prepared.entityID,
                               reference: input.entity_id,
                               summary: "Set collider trigger",
                               mutation: .setCollider(entityID: prepared.entityID,
                                                      collider: collider))
    }
}

public struct SetColliderLayerCapability: GuavaCapability {
    public struct Input: DeclaredCapabilityInput {
        @EntityReference
        public var entity_id: SceneEntityRef

        @ValueRange(min: 0, max: 15)
        public var collider_layer_id: Int?

        @ValueRange(min: 0, max: 65_535)
        public var collider_layer_mask: Int?

        public init() {}
    }

    public static let id = "scene.set_collider_layer"
    public static let title = "Set collider layers"
    public static let description = "Create or update collider layer id and interaction mask."
    public static let domain = "scene"
    public static let access = CapabilityAccess.reversibleWrite
    public static let releasePhase = CapabilityReleasePhase.beta

    public static func prepare(input: Input,
                               context: CapabilityPreparationContext) throws -> PreparedCapability {
        guard input.collider_layer_id != nil || input.collider_layer_mask != nil else {
            throw PhysicsCapabilityPreparationError.noLayerFields
        }
        let prepared = try preparedPhysicsEntity(input.entity_id, context: context)
        var collider = prepared.entity.collider ?? defaultCollider()
        if let value = input.collider_layer_id { collider.layerID = UInt16(value) }
        if let value = input.collider_layer_mask { collider.layerMask = UInt16(value) }
        return physicsPrepared(entityID: prepared.entityID,
                               reference: input.entity_id,
                               summary: "Set collider layers",
                               mutation: .setCollider(entityID: prepared.entityID,
                                                      collider: collider))
    }
}

private func physicsPrepared(
    entityID: UInt64,
    reference: SceneEntityRef,
    summary: String,
    mutation: SceneMutation
) -> PreparedCapability {
    PreparedCapability(
        operations: [.scene(mutation)],
        preview: CapabilityPreview(summary: summary,
                                   targetReferences: [reference.rawValue]),
        assertions: [.entityExists(entityID)]
    )
}

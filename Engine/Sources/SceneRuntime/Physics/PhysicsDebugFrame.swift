import Foundation
import SIMDCompat

public struct PhysicsDebugBody: Sendable, Equatable {
    public var entity: EntityID
    public var shape: ColliderShape
    public var shapes: [ColliderShapeInstance]
    public var worldTransform: WorldTransform
    public var bounds: SpatialAABB
    public var motionType: RigidBodyMotionType
    public var isTrigger: Bool
    public var isSleeping: Bool

    public init(
        entity: EntityID,
        shape: ColliderShape,
        shapes: [ColliderShapeInstance]? = nil,
        worldTransform: WorldTransform,
        bounds: SpatialAABB,
        motionType: RigidBodyMotionType,
        isTrigger: Bool,
        isSleeping: Bool
    ) {
        self.entity = entity
        self.shape = shape
        self.shapes = shapes ?? [ColliderShapeInstance(shape: shape)]
        self.worldTransform = worldTransform
        self.bounds = bounds
        self.motionType = motionType
        self.isTrigger = isTrigger
        self.isSleeping = isSleeping
    }
}

public struct PhysicsDebugConstraint: Sendable, Equatable {
    public var entity: EntityID
    public var constraintType: ConstraintType
    public var configuration: PhysicsJointConfiguration
    public var entityA: EntityID
    public var entityB: EntityID
    public var pivotA: SIMD3<Float>
    public var pivotB: SIMD3<Float>
    public var axisA: SIMD3<Float>
    public var axisB: SIMD3<Float>
    public var minimumLimit: Float
    public var maximumLimit: Float
    public var breakForce: Float
    public var breakTorque: Float
    public var isEnabled: Bool

    public init(entity: EntityID, constraint: Constraint) {
        self.entity = entity
        constraintType = constraint.constraintType
        configuration = constraint.configuration
        entityA = constraint.entityA
        entityB = constraint.entityB
        pivotA = constraint.pivotA
        pivotB = constraint.pivotB
        axisA = constraint.axisA
        axisB = constraint.axisB
        minimumLimit = constraint.minLimit
        maximumLimit = constraint.maxLimit
        breakForce = constraint.breakForce
        breakTorque = constraint.breakTorque
        isEnabled = constraint.isEnabled
    }
}

public struct PhysicsDebugDestructionConnection: Sendable, Equatable {
    public var sourceEntity: EntityID
    public var connectionID: UInt32
    public var fragmentA: UInt32
    public var fragmentB: UInt32
    public var worldPointA: SIMD3<Float>
    public var worldPointB: SIMD3<Float>
    public var isBroken: Bool
    public var isSourceFractured: Bool

    public init(
        sourceEntity: EntityID,
        connectionID: UInt32,
        fragmentA: UInt32,
        fragmentB: UInt32,
        worldPointA: SIMD3<Float>,
        worldPointB: SIMD3<Float>,
        isBroken: Bool,
        isSourceFractured: Bool
    ) {
        self.sourceEntity = sourceEntity
        self.connectionID = connectionID
        self.fragmentA = fragmentA
        self.fragmentB = fragmentB
        self.worldPointA = worldPointA
        self.worldPointB = worldPointB
        self.isBroken = isBroken
        self.isSourceFractured = isSourceFractured
    }
}

public struct PhysicsDebugFrameResource: Sendable, Equatable {
    public var bodies: [PhysicsDebugBody]
    public var constraints: [PhysicsDebugConstraint]
    public var contacts: [PhysicsContactEvent]
    public var characters: [CharacterState]
    public var destructionConnections: [PhysicsDebugDestructionConnection]

    public init(
        bodies: [PhysicsDebugBody] = [],
        constraints: [PhysicsDebugConstraint] = [],
        contacts: [PhysicsContactEvent] = [],
        characters: [CharacterState] = [],
        destructionConnections: [PhysicsDebugDestructionConnection] = []
    ) {
        self.bodies = bodies
        self.constraints = constraints
        self.contacts = contacts
        self.characters = characters
        self.destructionConnections = destructionConnections
    }

    public static let empty = PhysicsDebugFrameResource()
}

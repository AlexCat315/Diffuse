import SIMDCompat

public enum PhysicsSimulationMode: String, CaseIterable, Sendable, Equatable {
    case off
    case preview
    case play
    case bake
}

public enum PhysicsBackendKind: String, Sendable, Equatable {
    case none
    case jolt
}

public enum PhysicsBackendErrorCode: String, Sendable, Equatable {
    case abiMismatch
    case invalidArgument
    case invalidShape
    case bodyCreationFailed
    case updateFailed
    case unknown
}

public struct PhysicsBackendError: Error, Sendable, Equatable {
    public var code: PhysicsBackendErrorCode
    public var message: String

    public init(code: PhysicsBackendErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum RigidBodyMotionType: String, CaseIterable, Sendable, Equatable {
    case `static`
    case dynamic
    case kinematic
}

public struct RigidBody: RuntimeComponent, Sendable, Equatable {
    public var motionType: RigidBodyMotionType
    public var mass: Float
    public var linearVelocity: SIMD3<Float>
    public var angularVelocity: SIMD3<Float>
    public var accumulatedForce: SIMD3<Float>
    public var accumulatedTorque: SIMD3<Float>
    public var accumulatedLinearImpulse: SIMD3<Float>
    public var accumulatedAngularImpulse: SIMD3<Float>
    public var gravityScale: Float
    public var linearDamping: Float
    public var angularDamping: Float
    public var allowSleep: Bool
    public var isSleeping: Bool
    public var continuousCollisionDetection: Bool

    public init(
        motionType: RigidBodyMotionType = .dynamic,
        mass: Float = 1,
        linearVelocity: SIMD3<Float> = .zero,
        angularVelocity: SIMD3<Float> = .zero,
        accumulatedForce: SIMD3<Float> = .zero,
        accumulatedTorque: SIMD3<Float> = .zero,
        accumulatedLinearImpulse: SIMD3<Float> = .zero,
        accumulatedAngularImpulse: SIMD3<Float> = .zero,
        gravityScale: Float = 1,
        linearDamping: Float = 0.04,
        angularDamping: Float = 0.04,
        allowSleep: Bool = true,
        isSleeping: Bool = false,
        continuousCollisionDetection: Bool = false
    ) {
        self.motionType = motionType
        self.mass = mass
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
        self.accumulatedForce = accumulatedForce
        self.accumulatedTorque = accumulatedTorque
        self.accumulatedLinearImpulse = accumulatedLinearImpulse
        self.accumulatedAngularImpulse = accumulatedAngularImpulse
        self.gravityScale = gravityScale
        self.linearDamping = linearDamping
        self.angularDamping = angularDamping
        self.allowSleep = allowSleep
        self.isSleeping = isSleeping
        self.continuousCollisionDetection = continuousCollisionDetection
    }
}

public enum ColliderShapeKind: String, CaseIterable, Sendable, Equatable {
    case box
    case sphere
    case capsule
    case mesh
    case convex
}

public enum ColliderShape: Sendable, Equatable {
    case box(halfExtents: SIMD3<Float>, center: SIMD3<Float>)
    case sphere(radius: Float, center: SIMD3<Float>)
    case capsule(radius: Float, halfHeight: Float, center: SIMD3<Float>)
    case mesh(resourceID: String?, center: SIMD3<Float>)
    case convex(resourceID: String?, center: SIMD3<Float>)

    public var kind: ColliderShapeKind {
        switch self {
        case .box: return .box
        case .sphere: return .sphere
        case .capsule: return .capsule
        case .mesh: return .mesh
        case .convex: return .convex
        }
    }

    public var center: SIMD3<Float> {
        switch self {
        case let .box(_, center),
             let .sphere(_, center),
             let .capsule(_, _, center),
             let .mesh(_, center),
             let .convex(_, center):
            return center
        }
    }

    public var resourceID: String? {
        switch self {
        case let .mesh(resourceID, _),
             let .convex(resourceID, _):
            return resourceID
        default:
            return nil
        }
    }

    public func replacingCenter(with center: SIMD3<Float>) -> ColliderShape {
        switch self {
        case let .box(halfExtents, _):
            return .box(halfExtents: halfExtents, center: center)
        case let .sphere(radius, _):
            return .sphere(radius: radius, center: center)
        case let .capsule(radius, halfHeight, _):
            return .capsule(radius: radius, halfHeight: halfHeight, center: center)
        case let .mesh(resourceID, _):
            return .mesh(resourceID: resourceID, center: center)
        case let .convex(resourceID, _):
            return .convex(resourceID: resourceID, center: center)
        }
    }
}

public struct PhysicsMaterial: Sendable, Equatable {
    public var friction: Float
    public var restitution: Float
    public var density: Float

    public init(friction: Float = 0.6, restitution: Float = 0, density: Float = 1) {
        self.friction = max(0, friction)
        self.restitution = max(0, min(restitution, 1))
        self.density = max(0, density)
    }
}

public struct Collider: RuntimeComponent, Sendable, Equatable {
    public var shape: ColliderShape
    public var isTrigger: Bool
    public var layerID: UInt16
    public var layerMask: UInt16
    public var material: PhysicsMaterial

    public init(
        shape: ColliderShape,
        isTrigger: Bool = false,
        layerID: UInt16 = 0,
        layerMask: UInt16 = .max,
        material: PhysicsMaterial = PhysicsMaterial()
    ) {
        self.shape = shape
        self.isTrigger = isTrigger
        self.layerID = layerID
        self.layerMask = layerMask
        self.material = material
    }
}

public enum CharacterStance: UInt8, Sendable, Equatable, Codable {
    case standing
    case crouching
}

/// Authored configuration for a native Jolt virtual character.
/// Character entities do not require a `RigidBody` or `Collider`; this component owns
/// the capsule used by the character solver.
public struct CharacterController: RuntimeComponent, Sendable, Equatable {
    public var radius: Float
    public var standingHalfHeight: Float
    public var crouchingHalfHeight: Float
    public var center: SIMD3<Float>
    public var maxSlopeDegrees: Float
    public var stepHeight: Float
    public var skinWidth: Float
    public var mass: Float
    public var maxStrength: Float
    public var gravityScale: Float
    public var layerID: UInt16
    public var layerMask: UInt16

    public init(
        radius: Float = 0.4,
        standingHalfHeight: Float = 0.6,
        crouchingHalfHeight: Float = 0.25,
        center: SIMD3<Float> = .zero,
        maxSlopeDegrees: Float = 50,
        stepHeight: Float = 0.4,
        skinWidth: Float = 0.02,
        mass: Float = 70,
        maxStrength: Float = 100,
        gravityScale: Float = 1,
        layerID: UInt16 = 0,
        layerMask: UInt16 = .max
    ) {
        self.radius = max(0.01, radius)
        self.standingHalfHeight = max(0.01, standingHalfHeight)
        self.crouchingHalfHeight = max(0.01, min(crouchingHalfHeight, standingHalfHeight))
        self.center = center
        self.maxSlopeDegrees = max(0, min(maxSlopeDegrees, 89.9))
        self.stepHeight = max(0, stepHeight)
        self.skinWidth = max(0.001, skinWidth)
        self.mass = max(0.01, mass)
        self.maxStrength = max(0, maxStrength)
        self.gravityScale = gravityScale
        self.layerID = layerID
        self.layerMask = layerMask
    }
}

public struct CharacterCommand: Sendable, Equatable {
    public var desiredVelocity: SIMD3<Float>
    public var jumpRequested: Bool
    public var jumpSpeed: Float
    public var stance: CharacterStance

    public init(
        desiredVelocity: SIMD3<Float> = .zero,
        jumpRequested: Bool = false,
        jumpSpeed: Float = 8,
        stance: CharacterStance = .standing
    ) {
        self.desiredVelocity = desiredVelocity
        self.jumpRequested = jumpRequested
        self.jumpSpeed = max(0, jumpSpeed)
        self.stance = stance
    }
}

public struct CharacterCommandFrameResource: Sendable, Equatable {
    public var commands: [EntityID: CharacterCommand]

    public init(commands: [EntityID: CharacterCommand] = [:]) {
        self.commands = commands
    }

    public static let empty = CharacterCommandFrameResource()
}

public enum CharacterGroundState: UInt8, Sendable, Equatable {
    case onGround
    case onSteepGround
    case notSupported
    case inAir
}

public struct CharacterState: Sendable, Equatable {
    public var entity: EntityID
    public var position: SIMD3<Float>
    public var rotation: SIMD4<Float>
    public var linearVelocity: SIMD3<Float>
    public var groundState: CharacterGroundState
    public var groundNormal: SIMD3<Float>
    public var groundVelocity: SIMD3<Float>
    public var groundEntity: EntityID?
    public var stance: CharacterStance

    public init(
        entity: EntityID,
        position: SIMD3<Float>,
        rotation: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        linearVelocity: SIMD3<Float> = .zero,
        groundState: CharacterGroundState = .inAir,
        groundNormal: SIMD3<Float> = .zero,
        groundVelocity: SIMD3<Float> = .zero,
        groundEntity: EntityID? = nil,
        stance: CharacterStance = .standing
    ) {
        self.entity = entity
        self.position = position
        self.rotation = rotation
        self.linearVelocity = linearVelocity
        self.groundState = groundState
        self.groundNormal = groundNormal
        self.groundVelocity = groundVelocity
        self.groundEntity = groundEntity
        self.stance = stance
    }

    public var isGrounded: Bool { groundState == .onGround }
}

public struct CharacterStateFrameResource: Sendable, Equatable {
    public var states: [EntityID: CharacterState]

    public init(states: [EntityID: CharacterState] = [:]) {
        self.states = states
    }

    public static let empty = CharacterStateFrameResource()
}

public enum ConstraintType: String, Sendable, Equatable {
    case pointToPoint
    case hinge
    case fixed
    case slider
    case distance
}

public struct Constraint: RuntimeComponent, Sendable, Equatable {
    public var constraintType: ConstraintType
    public var entityA: EntityID
    public var entityB: EntityID
    public var pivotA: SIMD3<Float>
    public var pivotB: SIMD3<Float>
    public var axisA: SIMD3<Float>
    public var axisB: SIMD3<Float>
    public var minLimit: Float
    public var maxLimit: Float
    public var isEnabled: Bool

    public init(
        constraintType: ConstraintType = .pointToPoint,
        entityA: EntityID,
        entityB: EntityID,
        pivotA: SIMD3<Float> = .zero,
        pivotB: SIMD3<Float> = .zero,
        axisA: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        axisB: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        minLimit: Float = 0,
        maxLimit: Float = 0,
        isEnabled: Bool = true
    ) {
        self.constraintType = constraintType
        self.entityA = entityA
        self.entityB = entityB
        self.pivotA = pivotA
        self.pivotB = pivotB
        self.axisA = axisA
        self.axisB = axisB
        self.minLimit = minLimit
        self.maxLimit = maxLimit
        self.isEnabled = isEnabled
    }
}

public struct PhysicsSettingsResource: Sendable, Equatable {
    public var simulationMode: PhysicsSimulationMode
    public var backendKind: PhysicsBackendKind
    public var gravity: SIMD3<Float>
    public var fixedTimeStepSeconds: Double
    public var maxSubstepsPerFrame: Int
    public var allowSleep: Bool
    public var collisionSteps: Int

    public init(
        simulationMode: PhysicsSimulationMode = .off,
        backendKind: PhysicsBackendKind = .jolt,
        gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0),
        fixedTimeStepSeconds: Double = 1.0 / 60.0,
        maxSubstepsPerFrame: Int = 4,
        allowSleep: Bool = true,
        collisionSteps: Int = 1
    ) {
        self.simulationMode = simulationMode
        self.backendKind = backendKind
        self.gravity = gravity
        self.fixedTimeStepSeconds = max(0.000_001, fixedTimeStepSeconds)
        self.maxSubstepsPerFrame = max(1, maxSubstepsPerFrame)
        self.allowSleep = allowSleep
        self.collisionSteps = max(1, collisionSteps)
    }
}

public struct PhysicsStepClockResource: Sendable, Equatable {
    public var accumulatedSeconds: Double
    public var simulatedSteps: Int
    public var lastStepCount: Int
    public var lastSteppedSeconds: Double
    public var droppedSteps: Int
    public var lastDroppedStepCount: Int

    public init(
        accumulatedSeconds: Double = 0,
        simulatedSteps: Int = 0,
        lastStepCount: Int = 0,
        lastSteppedSeconds: Double = 0,
        droppedSteps: Int = 0,
        lastDroppedStepCount: Int = 0
    ) {
        self.accumulatedSeconds = accumulatedSeconds
        self.simulatedSteps = simulatedSteps
        self.lastStepCount = lastStepCount
        self.lastSteppedSeconds = lastSteppedSeconds
        self.droppedSteps = droppedSteps
        self.lastDroppedStepCount = lastDroppedStepCount
    }
}

public struct PhysicsFrameStateResource: Sendable, Equatable {
    public var backendIdentifier: String
    public var bodyCount: Int
    public var constraintCount: Int
    public var contactCount: Int
    public var writebackCount: Int
    public var simulatedSteps: Int
    public var simulatedSeconds: Double
    public var synchronizedBodyCount: Int
    public var synchronizedConstraintCount: Int
    public var activeBodyCount: Int
    public var droppedStepCount: Int
    public var synchronizationNanoseconds: UInt64
    public var stepNanoseconds: UInt64
    public var lastError: PhysicsBackendError?

    public init(
        backendIdentifier: String = "none",
        bodyCount: Int = 0,
        constraintCount: Int = 0,
        contactCount: Int = 0,
        writebackCount: Int = 0,
        simulatedSteps: Int = 0,
        simulatedSeconds: Double = 0,
        synchronizedBodyCount: Int = 0,
        synchronizedConstraintCount: Int = 0,
        activeBodyCount: Int = 0,
        droppedStepCount: Int = 0,
        synchronizationNanoseconds: UInt64 = 0,
        stepNanoseconds: UInt64 = 0,
        lastError: PhysicsBackendError? = nil
    ) {
        self.backendIdentifier = backendIdentifier
        self.bodyCount = bodyCount
        self.constraintCount = constraintCount
        self.contactCount = contactCount
        self.writebackCount = writebackCount
        self.simulatedSteps = simulatedSteps
        self.simulatedSeconds = simulatedSeconds
        self.synchronizedBodyCount = synchronizedBodyCount
        self.synchronizedConstraintCount = synchronizedConstraintCount
        self.activeBodyCount = activeBodyCount
        self.droppedStepCount = droppedStepCount
        self.synchronizationNanoseconds = synchronizationNanoseconds
        self.stepNanoseconds = stepNanoseconds
        self.lastError = lastError
    }
}

public struct PhysicsDebugBody: Sendable, Equatable {
    public var entity: EntityID
    public var shape: ColliderShape
    public var worldTransform: WorldTransform
    public var bounds: SpatialAABB
    public var motionType: RigidBodyMotionType
    public var isTrigger: Bool
    public var isSleeping: Bool

    public init(
        entity: EntityID,
        shape: ColliderShape,
        worldTransform: WorldTransform,
        bounds: SpatialAABB,
        motionType: RigidBodyMotionType,
        isTrigger: Bool,
        isSleeping: Bool
    ) {
        self.entity = entity
        self.shape = shape
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
    public var entityA: EntityID
    public var entityB: EntityID
    public var pivotA: SIMD3<Float>
    public var pivotB: SIMD3<Float>
    public var axisA: SIMD3<Float>
    public var axisB: SIMD3<Float>
    public var isEnabled: Bool

    public init(entity: EntityID, constraint: Constraint) {
        self.entity = entity
        constraintType = constraint.constraintType
        entityA = constraint.entityA
        entityB = constraint.entityB
        pivotA = constraint.pivotA
        pivotB = constraint.pivotB
        axisA = constraint.axisA
        axisB = constraint.axisB
        isEnabled = constraint.isEnabled
    }
}

public struct PhysicsDebugFrameResource: Sendable, Equatable {
    public var bodies: [PhysicsDebugBody]
    public var constraints: [PhysicsDebugConstraint]
    public var contacts: [PhysicsContactEvent]

    public init(
        bodies: [PhysicsDebugBody] = [],
        constraints: [PhysicsDebugConstraint] = [],
        contacts: [PhysicsContactEvent] = []
    ) {
        self.bodies = bodies
        self.constraints = constraints
        self.contacts = contacts
    }

    public static let empty = PhysicsDebugFrameResource()
}

public enum PhysicsContactEventKind: String, Sendable, Equatable {
    case began
    case stayed
    case ended
}

public struct PhysicsContactEvent: Sendable, Equatable {
    public var entityA: EntityID
    public var entityB: EntityID
    public var kind: PhysicsContactEventKind
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var penetrationDepth: Float

    public init(
        entityA: EntityID,
        entityB: EntityID,
        kind: PhysicsContactEventKind,
        position: SIMD3<Float> = .zero,
        normal: SIMD3<Float> = .zero,
        penetrationDepth: Float = 0
    ) {
        self.entityA = entityA
        self.entityB = entityB
        self.kind = kind
        self.position = position
        self.normal = normal
        self.penetrationDepth = penetrationDepth
    }
}

public struct PhysicsContactFrameResource: Sendable, Equatable {
    public var began: [PhysicsContactEvent]
    public var stayed: [PhysicsContactEvent]
    public var ended: [PhysicsContactEvent]

    public init(
        began: [PhysicsContactEvent] = [],
        stayed: [PhysicsContactEvent] = [],
        ended: [PhysicsContactEvent] = []
    ) {
        self.began = began
        self.stayed = stayed
        self.ended = ended
    }

    public init(events: [PhysicsContactEvent]) {
        began = events.filter { $0.kind == .began }
        stayed = events.filter { $0.kind == .stayed }
        ended = events.filter { $0.kind == .ended }
    }

    public var events: [PhysicsContactEvent] {
        began + stayed + ended
    }

    public static let empty = PhysicsContactFrameResource()
}

public struct PhysicsQueryFilter: Sendable, Equatable {
    public var excludeEntity: EntityID?
    public var includeTriggers: Bool
    public var layerID: UInt16?
    public var layerMask: UInt16

    public init(
        excludeEntity: EntityID? = nil,
        includeTriggers: Bool = false,
        layerID: UInt16? = nil,
        layerMask: UInt16 = .max
    ) {
        self.excludeEntity = excludeEntity
        self.includeTriggers = includeTriggers
        self.layerID = layerID
        self.layerMask = layerMask
    }
}

public struct PhysicsRaycastQuery: Sendable, Equatable {
    public var origin: SIMD3<Float>
    public var direction: SIMD3<Float>
    public var maxDistance: Float

    public init(origin: SIMD3<Float>,
                direction: SIMD3<Float>,
                maxDistance: Float = .greatestFiniteMagnitude) {
        self.origin = origin
        self.direction = direction
        self.maxDistance = maxDistance
    }
}

public struct PhysicsRaycastHit: Sendable, Equatable {
    public var entity: EntityID
    public var distance: Float
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(entity: EntityID,
                distance: Float,
                position: SIMD3<Float>,
                normal: SIMD3<Float>,
                bounds: SpatialAABB,
                isTrigger: Bool) {
        self.entity = entity
        self.distance = distance
        self.position = position
        self.normal = normal
        self.bounds = bounds
        self.isTrigger = isTrigger
    }
}

public struct PhysicsOverlapAABBQuery: Sendable, Equatable {
    public var bounds: SpatialAABB
    /// Stop collecting hits after this many results. Default (.max) collects all.
    /// When set, sort order is not guaranteed.
    public var maxResults: Int

    public init(bounds: SpatialAABB, maxResults: Int = .max) {
        self.bounds = bounds
        self.maxResults = max(maxResults, 0)
    }
}

public struct PhysicsOverlapHit: Sendable, Equatable {
    public var entity: EntityID
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(entity: EntityID, bounds: SpatialAABB, isTrigger: Bool) {
        self.entity = entity
        self.bounds = bounds
        self.isTrigger = isTrigger
    }
}

public enum PhysicsQueryShape: Sendable, Equatable {
    case box(halfExtents: SIMD3<Float>)
    case sphere(radius: Float)
    case capsule(radius: Float, halfHeight: Float)
}

public struct PhysicsOverlapShapeQuery: Sendable, Equatable {
    public var shape: PhysicsQueryShape
    public var position: SIMD3<Float>
    /// Quaternion stored as (x, y, z, w). Capsules are aligned to local Y before rotation.
    public var rotation: SIMD4<Float>
    /// Stop collecting hits after this many results. Default (.max) collects all.
    public var maxResults: Int

    public init(
        shape: PhysicsQueryShape,
        position: SIMD3<Float>,
        rotation: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        maxResults: Int = .max
    ) {
        self.shape = shape
        self.position = position
        self.rotation = rotation
        self.maxResults = max(maxResults, 0)
    }
}

public struct PhysicsSweepAABBQuery: Sendable, Equatable {
    public var bounds: SpatialAABB
    public var translation: SIMD3<Float>

    public init(bounds: SpatialAABB, translation: SIMD3<Float>) {
        self.bounds = bounds
        self.translation = translation
    }
}

public struct PhysicsSweepShapeQuery: Sendable, Equatable {
    public var shape: PhysicsQueryShape
    public var position: SIMD3<Float>
    /// Quaternion stored as (x, y, z, w). Capsules are aligned to local Y before rotation.
    public var rotation: SIMD4<Float>
    public var translation: SIMD3<Float>

    public init(
        shape: PhysicsQueryShape,
        position: SIMD3<Float>,
        rotation: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        translation: SIMD3<Float>
    ) {
        self.shape = shape
        self.position = position
        self.rotation = rotation
        self.translation = translation
    }
}

public struct PhysicsSweepHit: Sendable, Equatable {
    public var entity: EntityID
    public var fraction: Float
    public var distance: Float
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(entity: EntityID,
                fraction: Float,
                distance: Float,
                position: SIMD3<Float>,
                normal: SIMD3<Float>,
                bounds: SpatialAABB,
                isTrigger: Bool) {
        self.entity = entity
        self.fraction = fraction
        self.distance = distance
        self.position = position
        self.normal = normal
        self.bounds = bounds
        self.isTrigger = isTrigger
    }
}

public struct PhysicsBodyDescriptor: Sendable, Equatable {
    public var entity: EntityID
    public var localTransform: LocalTransform
    public var worldTransform: WorldTransform
    public var rigidBody: RigidBody?
    public var collider: Collider?
    public var meshGeometry: MeshColliderGeometry?

    public init(
        entity: EntityID,
        localTransform: LocalTransform,
        worldTransform: WorldTransform,
        rigidBody: RigidBody?,
        collider: Collider?,
        meshGeometry: MeshColliderGeometry? = nil
    ) {
        self.entity = entity
        self.localTransform = localTransform
        self.worldTransform = worldTransform
        self.rigidBody = rigidBody
        self.collider = collider
        self.meshGeometry = meshGeometry
    }
}

public struct PhysicsConstraintDescriptor: Sendable, Equatable {
    public var entity: EntityID
    public var worldTransform: WorldTransform
    public var constraint: Constraint

    public init(entity: EntityID, worldTransform: WorldTransform, constraint: Constraint) {
        self.entity = entity
        self.worldTransform = worldTransform
        self.constraint = constraint
    }
}

public struct PhysicsCharacterDescriptor: Sendable, Equatable {
    public var entity: EntityID
    public var worldTransform: WorldTransform
    public var controller: CharacterController

    public init(entity: EntityID, worldTransform: WorldTransform, controller: CharacterController) {
        self.entity = entity
        self.worldTransform = worldTransform
        self.controller = controller
    }
}

public enum PhysicsSyncEvent: Sendable, Equatable {
    case bodyUpsert(PhysicsBodyDescriptor)
    case bodyRemove(EntityID)
    case constraintUpsert(PhysicsConstraintDescriptor)
    case constraintRemove(EntityID)
}

public struct PhysicsPrepareContext: Sendable {
    public var settings: PhysicsSettingsResource
    public var deltaTimeSeconds: Double
    public var activeBodies: [PhysicsBodyDescriptor]
    public var activeConstraints: [PhysicsConstraintDescriptor]
    public var syncEvents: [PhysicsSyncEvent]
    public var activeCharacters: [PhysicsCharacterDescriptor]

    public init(
        settings: PhysicsSettingsResource,
        deltaTimeSeconds: Double,
        activeBodies: [PhysicsBodyDescriptor],
        activeConstraints: [PhysicsConstraintDescriptor],
        syncEvents: [PhysicsSyncEvent],
        activeCharacters: [PhysicsCharacterDescriptor] = []
    ) {
        self.settings = settings
        self.deltaTimeSeconds = deltaTimeSeconds
        self.activeBodies = activeBodies
        self.activeConstraints = activeConstraints
        self.syncEvents = syncEvents
        self.activeCharacters = activeCharacters
    }
}

public struct PhysicsPrepareResult: Sendable, Equatable {
    public var synchronizedBodies: Int
    public var synchronizedConstraints: Int
    public var removedBodies: Int
    public var removedConstraints: Int
    public var error: PhysicsBackendError?

    public init(
        synchronizedBodies: Int = 0,
        synchronizedConstraints: Int = 0,
        removedBodies: Int = 0,
        removedConstraints: Int = 0,
        error: PhysicsBackendError? = nil
    ) {
        self.synchronizedBodies = synchronizedBodies
        self.synchronizedConstraints = synchronizedConstraints
        self.removedBodies = removedBodies
        self.removedConstraints = removedConstraints
        self.error = error
    }
}

public struct PhysicsStepContext: Sendable {
    public var settings: PhysicsSettingsResource
    public var stepDeltaSeconds: Double
    public var stepIndex: Int
    public var activeBodies: [PhysicsBodyDescriptor]
    public var activeConstraints: [PhysicsConstraintDescriptor]
    public var activeCharacters: [PhysicsCharacterDescriptor]
    public var characterCommands: [EntityID: CharacterCommand]

    public init(
        settings: PhysicsSettingsResource,
        stepDeltaSeconds: Double,
        stepIndex: Int,
        activeBodies: [PhysicsBodyDescriptor],
        activeConstraints: [PhysicsConstraintDescriptor],
        activeCharacters: [PhysicsCharacterDescriptor] = [],
        characterCommands: [EntityID: CharacterCommand] = [:]
    ) {
        self.settings = settings
        self.stepDeltaSeconds = stepDeltaSeconds
        self.stepIndex = stepIndex
        self.activeBodies = activeBodies
        self.activeConstraints = activeConstraints
        self.activeCharacters = activeCharacters
        self.characterCommands = characterCommands
    }
}

public struct PhysicsBodyWriteback: Sendable, Equatable {
    public var entity: EntityID
    public var worldTransform: WorldTransform?
    public var linearVelocity: SIMD3<Float>?
    public var angularVelocity: SIMD3<Float>?
    public var isSleeping: Bool?

    public init(
        entity: EntityID,
        worldTransform: WorldTransform? = nil,
        linearVelocity: SIMD3<Float>? = nil,
        angularVelocity: SIMD3<Float>? = nil,
        isSleeping: Bool? = nil
    ) {
        self.entity = entity
        self.worldTransform = worldTransform
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
        self.isSleeping = isSleeping
    }
}

public struct PhysicsStepResult: Sendable, Equatable {
    public var bodyCount: Int
    public var constraintCount: Int
    public var contactCount: Int
    public var writebacks: [PhysicsBodyWriteback]
    public var contactEvents: [PhysicsContactEvent]
    public var characterStates: [CharacterState]
    public var error: PhysicsBackendError?

    public init(
        bodyCount: Int = 0,
        constraintCount: Int = 0,
        contactCount: Int = 0,
        writebacks: [PhysicsBodyWriteback] = [],
        contactEvents: [PhysicsContactEvent] = [],
        error: PhysicsBackendError? = nil,
        characterStates: [CharacterState] = []
    ) {
        self.bodyCount = bodyCount
        self.constraintCount = constraintCount
        self.contactCount = contactCount
        self.writebacks = writebacks
        self.contactEvents = contactEvents
        self.error = error
        self.characterStates = characterStates
    }
}

public protocol PhysicsBackend: AnyObject, Sendable {
    var identifier: String { get }
    func prepare(context: PhysicsPrepareContext) -> PhysicsPrepareResult
    func step(context: PhysicsStepContext) -> PhysicsStepResult
    func raycast(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter) -> PhysicsRaycastHit?
    func overlapAABB(_ query: PhysicsOverlapAABBQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit]
    func overlapShape(_ query: PhysicsOverlapShapeQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit]
    func sweepAABB(_ query: PhysicsSweepAABBQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit?
    func sweepShape(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit?
    func detectTriggerFrame(maxEventCount: Int) -> TriggerFrameResource
    func reset()
}

public final class NullPhysicsBackend: PhysicsBackend, @unchecked Sendable {
    public init() {}

    public var identifier: String {
        "none"
    }

    public func prepare(context: PhysicsPrepareContext) -> PhysicsPrepareResult {
        var upsertedBodies = 0
        var removedBodies = 0
        var upsertedConstraints = 0
        var removedConstraints = 0

        for event in context.syncEvents {
            switch event {
            case .bodyUpsert:
                upsertedBodies += 1
            case .bodyRemove:
                removedBodies += 1
            case .constraintUpsert:
                upsertedConstraints += 1
            case .constraintRemove:
                removedConstraints += 1
            }
        }

        return PhysicsPrepareResult(
            synchronizedBodies: upsertedBodies,
            synchronizedConstraints: upsertedConstraints,
            removedBodies: removedBodies,
            removedConstraints: removedConstraints
        )
    }

    public func step(context: PhysicsStepContext) -> PhysicsStepResult {
        PhysicsStepResult(
            bodyCount: context.activeBodies.count,
            constraintCount: context.activeConstraints.count,
            contactCount: 0,
            writebacks: []
        )
    }

    public func raycast(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter) -> PhysicsRaycastHit? {
        nil
    }

    public func overlapAABB(_ query: PhysicsOverlapAABBQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit] {
        []
    }

    public func overlapShape(_ query: PhysicsOverlapShapeQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit] {
        []
    }

    public func sweepAABB(_ query: PhysicsSweepAABBQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit? {
        nil
    }

    public func sweepShape(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit? {
        nil
    }

    public func detectTriggerFrame(maxEventCount: Int) -> TriggerFrameResource {
        TriggerFrameResource()
    }

    public func reset() {}
}

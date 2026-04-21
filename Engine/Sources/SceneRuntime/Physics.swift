import simd

public enum PhysicsSimulationMode: String, Sendable, Equatable {
    case off
    case preview
    case play
    case bake
}

public enum PhysicsBackendKind: String, Sendable, Equatable {
    case none
    case jolt
}

public enum RigidBodyMotionType: String, Sendable, Equatable {
    case `static`
    case dynamic
    case kinematic
}

public struct RigidBody: RuntimeComponent, Sendable, Equatable {
    public var motionType: RigidBodyMotionType
    public var mass: Float
    public var linearVelocity: SIMD3<Float>
    public var angularVelocity: SIMD3<Float>
    public var gravityScale: Float
    public var linearDamping: Float
    public var angularDamping: Float
    public var allowSleep: Bool
    public var isSleeping: Bool

    public init(
        motionType: RigidBodyMotionType = .dynamic,
        mass: Float = 1,
        linearVelocity: SIMD3<Float> = .zero,
        angularVelocity: SIMD3<Float> = .zero,
        gravityScale: Float = 1,
        linearDamping: Float = 0.04,
        angularDamping: Float = 0.04,
        allowSleep: Bool = true,
        isSleeping: Bool = false
    ) {
        self.motionType = motionType
        self.mass = mass
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
        self.gravityScale = gravityScale
        self.linearDamping = linearDamping
        self.angularDamping = angularDamping
        self.allowSleep = allowSleep
        self.isSleeping = isSleeping
    }
}

public enum ColliderShape: Sendable, Equatable {
    case box(halfExtents: SIMD3<Float>, center: SIMD3<Float>)
    case sphere(radius: Float, center: SIMD3<Float>)
    case capsule(radius: Float, halfHeight: Float, center: SIMD3<Float>)
    case mesh(resourceID: String?, center: SIMD3<Float>)
}

public struct Collider: RuntimeComponent, Sendable, Equatable {
    public var shape: ColliderShape
    public var isTrigger: Bool
    public var layerID: UInt16
    public var layerMask: UInt16

    public init(
        shape: ColliderShape,
        isTrigger: Bool = false,
        layerID: UInt16 = 0,
        layerMask: UInt16 = .max
    ) {
        self.shape = shape
        self.isTrigger = isTrigger
        self.layerID = layerID
        self.layerMask = layerMask
    }
}

public enum ConstraintType: String, Sendable, Equatable {
    case pointToPoint
    case hinge
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

    public init(
        simulationMode: PhysicsSimulationMode = .off,
        backendKind: PhysicsBackendKind = .none,
        gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0),
        fixedTimeStepSeconds: Double = 1.0 / 60.0,
        maxSubstepsPerFrame: Int = 4,
        allowSleep: Bool = true
    ) {
        self.simulationMode = simulationMode
        self.backendKind = backendKind
        self.gravity = gravity
        self.fixedTimeStepSeconds = fixedTimeStepSeconds
        self.maxSubstepsPerFrame = maxSubstepsPerFrame
        self.allowSleep = allowSleep
    }
}

public struct PhysicsStepClockResource: Sendable, Equatable {
    public var accumulatedSeconds: Double
    public var simulatedSteps: Int
    public var lastStepCount: Int
    public var lastSteppedSeconds: Double

    public init(
        accumulatedSeconds: Double = 0,
        simulatedSteps: Int = 0,
        lastStepCount: Int = 0,
        lastSteppedSeconds: Double = 0
    ) {
        self.accumulatedSeconds = accumulatedSeconds
        self.simulatedSteps = simulatedSteps
        self.lastStepCount = lastStepCount
        self.lastSteppedSeconds = lastSteppedSeconds
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

    public init(
        backendIdentifier: String = "none",
        bodyCount: Int = 0,
        constraintCount: Int = 0,
        contactCount: Int = 0,
        writebackCount: Int = 0,
        simulatedSteps: Int = 0,
        simulatedSeconds: Double = 0
    ) {
        self.backendIdentifier = backendIdentifier
        self.bodyCount = bodyCount
        self.constraintCount = constraintCount
        self.contactCount = contactCount
        self.writebackCount = writebackCount
        self.simulatedSteps = simulatedSteps
        self.simulatedSeconds = simulatedSeconds
    }
}

public struct PhysicsBodyDescriptor: Sendable, Equatable {
    public var entity: EntityID
    public var localTransform: LocalTransform
    public var worldTransform: WorldTransform
    public var rigidBody: RigidBody?
    public var collider: Collider?

    public init(
        entity: EntityID,
        localTransform: LocalTransform,
        worldTransform: WorldTransform,
        rigidBody: RigidBody?,
        collider: Collider?
    ) {
        self.entity = entity
        self.localTransform = localTransform
        self.worldTransform = worldTransform
        self.rigidBody = rigidBody
        self.collider = collider
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

    public init(
        settings: PhysicsSettingsResource,
        deltaTimeSeconds: Double,
        activeBodies: [PhysicsBodyDescriptor],
        activeConstraints: [PhysicsConstraintDescriptor],
        syncEvents: [PhysicsSyncEvent]
    ) {
        self.settings = settings
        self.deltaTimeSeconds = deltaTimeSeconds
        self.activeBodies = activeBodies
        self.activeConstraints = activeConstraints
        self.syncEvents = syncEvents
    }
}

public struct PhysicsPrepareResult: Sendable, Equatable {
    public var synchronizedBodies: Int
    public var synchronizedConstraints: Int
    public var removedBodies: Int
    public var removedConstraints: Int

    public init(
        synchronizedBodies: Int = 0,
        synchronizedConstraints: Int = 0,
        removedBodies: Int = 0,
        removedConstraints: Int = 0
    ) {
        self.synchronizedBodies = synchronizedBodies
        self.synchronizedConstraints = synchronizedConstraints
        self.removedBodies = removedBodies
        self.removedConstraints = removedConstraints
    }
}

public struct PhysicsStepContext: Sendable {
    public var settings: PhysicsSettingsResource
    public var stepDeltaSeconds: Double
    public var stepIndex: Int
    public var activeBodies: [PhysicsBodyDescriptor]
    public var activeConstraints: [PhysicsConstraintDescriptor]

    public init(
        settings: PhysicsSettingsResource,
        stepDeltaSeconds: Double,
        stepIndex: Int,
        activeBodies: [PhysicsBodyDescriptor],
        activeConstraints: [PhysicsConstraintDescriptor]
    ) {
        self.settings = settings
        self.stepDeltaSeconds = stepDeltaSeconds
        self.stepIndex = stepIndex
        self.activeBodies = activeBodies
        self.activeConstraints = activeConstraints
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

    public init(
        bodyCount: Int = 0,
        constraintCount: Int = 0,
        contactCount: Int = 0,
        writebacks: [PhysicsBodyWriteback] = []
    ) {
        self.bodyCount = bodyCount
        self.constraintCount = constraintCount
        self.contactCount = contactCount
        self.writebacks = writebacks
    }
}

public protocol PhysicsBackend: AnyObject, Sendable {
    var identifier: String { get }
    func prepare(context: PhysicsPrepareContext) -> PhysicsPrepareResult
    func step(context: PhysicsStepContext) -> PhysicsStepResult
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

    public func reset() {}
}

import Foundation
import SIMDCompat

public enum PhysicsSyncEvent: Sendable, Equatable {
    case bodyUpsert(PhysicsBodyDescriptor)
    case bodyRemove(EntityID)
    case constraintUpsert(PhysicsConstraintDescriptor)
    case constraintRemove(EntityID)
    case vehicleUpsert(PhysicsVehicleDescriptor)
    case vehicleRemove(EntityID)
    case softBodyUpsert(PhysicsSoftBodyDescriptor)
    case softBodyRemove(EntityID)
}

public struct PhysicsPrepareContext: Sendable {
    public var settings: PhysicsSettingsResource
    public var deltaTimeSeconds: Double
    public var activeBodies: [PhysicsBodyDescriptor]
    public var activeConstraints: [PhysicsConstraintDescriptor]
    public var syncEvents: [PhysicsSyncEvent]
    public var activeCharacters: [PhysicsCharacterDescriptor]
    public var activeVehicles: [PhysicsVehicleDescriptor]
    public var activeSoftBodies: [PhysicsSoftBodyDescriptor]
    /// Full snapshots remove native objects that are absent from `activeBodies` / `activeConstraints`.
    /// Runtime simulation normally uses ordered incremental `syncEvents` instead.
    public var isFullSnapshot: Bool

    public init(
        settings: PhysicsSettingsResource,
        deltaTimeSeconds: Double,
        activeBodies: [PhysicsBodyDescriptor],
        activeConstraints: [PhysicsConstraintDescriptor],
        syncEvents: [PhysicsSyncEvent],
        activeCharacters: [PhysicsCharacterDescriptor] = [],
        activeVehicles: [PhysicsVehicleDescriptor] = [],
        activeSoftBodies: [PhysicsSoftBodyDescriptor] = [],
        isFullSnapshot: Bool = false
    ) {
        self.settings = settings
        self.deltaTimeSeconds = deltaTimeSeconds
        self.activeBodies = activeBodies
        self.activeConstraints = activeConstraints
        self.syncEvents = syncEvents
        self.activeCharacters = activeCharacters
        self.activeVehicles = activeVehicles
        self.activeSoftBodies = activeSoftBodies
        self.isFullSnapshot = isFullSnapshot
    }
}

public struct PhysicsPrepareResult: Sendable, Equatable {
    public var synchronizedBodies: Int
    public var synchronizedConstraints: Int
    public var removedBodies: Int
    public var removedConstraints: Int
    public var synchronizedVehicles: Int
    public var removedVehicles: Int
    public var synchronizedSoftBodies: Int
    public var removedSoftBodies: Int
    public var error: PhysicsBackendError?

    public init(
        synchronizedBodies: Int = 0,
        synchronizedConstraints: Int = 0,
        removedBodies: Int = 0,
        removedConstraints: Int = 0,
        synchronizedVehicles: Int = 0,
        removedVehicles: Int = 0,
        synchronizedSoftBodies: Int = 0,
        removedSoftBodies: Int = 0,
        error: PhysicsBackendError? = nil
    ) {
        self.synchronizedBodies = synchronizedBodies
        self.synchronizedConstraints = synchronizedConstraints
        self.removedBodies = removedBodies
        self.removedConstraints = removedConstraints
        self.synchronizedVehicles = synchronizedVehicles
        self.removedVehicles = removedVehicles
        self.synchronizedSoftBodies = synchronizedSoftBodies
        self.removedSoftBodies = removedSoftBodies
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
    public var activeVehicles: [PhysicsVehicleDescriptor]
    public var vehicleCommands: [EntityID: VehicleCommand]
    public var activeSoftBodies: [PhysicsSoftBodyDescriptor]

    public init(
        settings: PhysicsSettingsResource,
        stepDeltaSeconds: Double,
        stepIndex: Int,
        activeBodies: [PhysicsBodyDescriptor],
        activeConstraints: [PhysicsConstraintDescriptor],
        activeCharacters: [PhysicsCharacterDescriptor] = [],
        characterCommands: [EntityID: CharacterCommand] = [:],
        activeVehicles: [PhysicsVehicleDescriptor] = [],
        vehicleCommands: [EntityID: VehicleCommand] = [:],
        activeSoftBodies: [PhysicsSoftBodyDescriptor] = []
    ) {
        self.settings = settings
        self.stepDeltaSeconds = stepDeltaSeconds
        self.stepIndex = stepIndex
        self.activeBodies = activeBodies
        self.activeConstraints = activeConstraints
        self.activeCharacters = activeCharacters
        self.characterCommands = characterCommands
        self.activeVehicles = activeVehicles
        self.vehicleCommands = vehicleCommands
        self.activeSoftBodies = activeSoftBodies
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
    public var jointBreakEvents: [PhysicsJointBreakEvent]
    public var characterStates: [CharacterState]
    public var vehicleStates: [VehicleState]
    public var softBodyStates: [SoftBodyMeshState]
    public var error: PhysicsBackendError?

    public init(
        bodyCount: Int = 0,
        constraintCount: Int = 0,
        contactCount: Int = 0,
        writebacks: [PhysicsBodyWriteback] = [],
        contactEvents: [PhysicsContactEvent] = [],
        jointBreakEvents: [PhysicsJointBreakEvent] = [],
        error: PhysicsBackendError? = nil,
        characterStates: [CharacterState] = [],
        vehicleStates: [VehicleState] = [],
        softBodyStates: [SoftBodyMeshState] = []
    ) {
        self.bodyCount = bodyCount
        self.constraintCount = constraintCount
        self.contactCount = contactCount
        self.writebacks = writebacks
        self.contactEvents = contactEvents
        self.jointBreakEvents = jointBreakEvents
        self.error = error
        self.characterStates = characterStates
        self.vehicleStates = vehicleStates
        self.softBodyStates = softBodyStates
    }
}

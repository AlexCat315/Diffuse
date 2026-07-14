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

public enum RigidBodyMassMode: String, Sendable, Equatable, Codable {
    case mass
    case density
}

public enum RigidBodyMotionQuality: String, Sendable, Equatable, Codable {
    case discrete
    case linearCast
}

public struct RigidBodyAxisLocks: OptionSet, Sendable, Equatable, Codable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let translationX = Self(rawValue: 1 << 0)
    public static let translationY = Self(rawValue: 1 << 1)
    public static let translationZ = Self(rawValue: 1 << 2)
    public static let rotationX = Self(rawValue: 1 << 3)
    public static let rotationY = Self(rawValue: 1 << 4)
    public static let rotationZ = Self(rawValue: 1 << 5)
}

public struct PhysicsKinematicTarget: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var rotation: SIMD4<Float>

    public init(
        position: SIMD3<Float>,
        rotation: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1)
    ) {
        self.position = position
        self.rotation = rotation
    }
}

public struct RigidBody: RuntimeComponent, Sendable, Equatable {
    public var motionType: RigidBodyMotionType
    public var mass: Float
    public var massMode: RigidBodyMassMode
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
    public var centerOfMassOverride: SIMD3<Float>?
    public var inertiaDiagonalOverride: SIMD3<Float>?
    public var axisLocks: RigidBodyAxisLocks
    public var maxLinearVelocity: Float
    public var maxAngularVelocity: Float
    public var motionQuality: RigidBodyMotionQuality
    public var kinematicTarget: PhysicsKinematicTarget?

    public init(
        motionType: RigidBodyMotionType = .dynamic,
        mass: Float = 1,
        massMode: RigidBodyMassMode = .mass,
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
        continuousCollisionDetection: Bool = false,
        centerOfMassOverride: SIMD3<Float>? = nil,
        inertiaDiagonalOverride: SIMD3<Float>? = nil,
        axisLocks: RigidBodyAxisLocks = [],
        maxLinearVelocity: Float = 500,
        maxAngularVelocity: Float = 0.25 * .pi * 60,
        motionQuality: RigidBodyMotionQuality = .discrete,
        kinematicTarget: PhysicsKinematicTarget? = nil
    ) {
        self.motionType = motionType
        self.mass = mass
        self.massMode = massMode
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
        self.centerOfMassOverride = centerOfMassOverride
        self.inertiaDiagonalOverride = inertiaDiagonalOverride
        self.axisLocks = axisLocks
        self.maxLinearVelocity = max(0, maxLinearVelocity)
        self.maxAngularVelocity = max(0, maxAngularVelocity)
        self.motionQuality = continuousCollisionDetection ? .linearCast : motionQuality
        self.kinematicTarget = kinematicTarget
    }
}

public enum ColliderShapeKind: String, CaseIterable, Sendable, Equatable {
    case box
    case sphere
    case capsule
    case cylinder
    case heightField
    case mesh
    case convex
}

public enum ColliderShape: Sendable, Equatable {
    case box(halfExtents: SIMD3<Float>, center: SIMD3<Float>)
    case sphere(radius: Float, center: SIMD3<Float>)
    case capsule(radius: Float, halfHeight: Float, center: SIMD3<Float>)
    case cylinder(radius: Float, halfHeight: Float, center: SIMD3<Float>)
    case heightField(resourceID: String?, center: SIMD3<Float>)
    case mesh(resourceID: String?, center: SIMD3<Float>)
    case convex(resourceID: String?, center: SIMD3<Float>)

    public var kind: ColliderShapeKind {
        switch self {
        case .box: return .box
        case .sphere: return .sphere
        case .capsule: return .capsule
        case .cylinder: return .cylinder
        case .heightField: return .heightField
        case .mesh: return .mesh
        case .convex: return .convex
        }
    }

    public var center: SIMD3<Float> {
        switch self {
        case let .box(_, center),
             let .sphere(_, center),
             let .capsule(_, _, center),
             let .cylinder(_, _, center),
             let .heightField(_, center),
             let .mesh(_, center),
             let .convex(_, center):
            return center
        }
    }

    public var resourceID: String? {
        switch self {
        case let .mesh(resourceID, _),
             let .heightField(resourceID, _),
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
        case let .cylinder(radius, halfHeight, _):
            return .cylinder(radius: radius, halfHeight: halfHeight, center: center)
        case let .heightField(resourceID, _):
            return .heightField(resourceID: resourceID, center: center)
        case let .mesh(resourceID, _):
            return .mesh(resourceID: resourceID, center: center)
        case let .convex(resourceID, _):
            return .convex(resourceID: resourceID, center: center)
        }
    }
}

public struct ColliderShapeInstance: Sendable, Equatable {
    public var shape: ColliderShape
    public var localPosition: SIMD3<Float>
    /// Quaternion encoded as (x, y, z, w).
    public var localRotation: SIMD4<Float>
    public var localScale: SIMD3<Float>

    public init(
        shape: ColliderShape,
        localPosition: SIMD3<Float> = .zero,
        localRotation: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        localScale: SIMD3<Float> = SIMD3<Float>(repeating: 1)
    ) {
        self.shape = shape
        self.localPosition = localPosition
        self.localRotation = localRotation
        self.localScale = localScale
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
    public var shapes: [ColliderShapeInstance]
    /// Compatibility access to the first child. New code should author `shapes`.
    public var shape: ColliderShape {
        get { shapes.first?.shape ?? .box(halfExtents: SIMD3<Float>(repeating: 0.5), center: .zero) }
        set {
            if shapes.isEmpty { shapes = [ColliderShapeInstance(shape: newValue)] }
            else { shapes[0].shape = newValue }
        }
    }
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
        self.shapes = [ColliderShapeInstance(shape: shape)]
        self.isTrigger = isTrigger
        self.layerID = layerID
        self.layerMask = layerMask
        self.material = material
    }

    public init(
        shapes: [ColliderShapeInstance],
        isTrigger: Bool = false,
        layerID: UInt16 = 0,
        layerMask: UInt16 = .max,
        material: PhysicsMaterial = PhysicsMaterial()
    ) {
        self.shapes = shapes
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

public enum VehicleTransmissionMode: UInt8, Sendable, Equatable, Codable {
    case automatic
    case manual
}

public struct VehicleWheelConfiguration: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var suspensionDirection: SIMD3<Float>
    public var steeringAxis: SIMD3<Float>
    public var wheelUp: SIMD3<Float>
    public var wheelForward: SIMD3<Float>
    public var suspensionMinLength: Float
    public var suspensionMaxLength: Float
    public var suspensionPreloadLength: Float
    public var suspensionFrequency: Float
    public var suspensionDamping: Float
    public var radius: Float
    public var width: Float
    public var inertia: Float
    public var angularDamping: Float
    public var maxSteerAngle: Float
    public var maxBrakeTorque: Float
    public var maxHandBrakeTorque: Float

    public init(
        position: SIMD3<Float>,
        suspensionDirection: SIMD3<Float> = SIMD3<Float>(0, -1, 0),
        steeringAxis: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        wheelUp: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        wheelForward: SIMD3<Float> = SIMD3<Float>(0, 0, 1),
        suspensionMinLength: Float = 0.2,
        suspensionMaxLength: Float = 0.5,
        suspensionPreloadLength: Float = 0,
        suspensionFrequency: Float = 1.5,
        suspensionDamping: Float = 0.5,
        radius: Float = 0.35,
        width: Float = 0.2,
        inertia: Float = 0.9,
        angularDamping: Float = 0.2,
        maxSteerAngle: Float = 0,
        maxBrakeTorque: Float = 1_500,
        maxHandBrakeTorque: Float = 0
    ) {
        self.position = position
        self.suspensionDirection = suspensionDirection
        self.steeringAxis = steeringAxis
        self.wheelUp = wheelUp
        self.wheelForward = wheelForward
        self.suspensionMinLength = max(0, min(suspensionMinLength, suspensionMaxLength))
        self.suspensionMaxLength = max(self.suspensionMinLength, suspensionMaxLength)
        self.suspensionPreloadLength = max(0, suspensionPreloadLength)
        self.suspensionFrequency = max(0, suspensionFrequency)
        self.suspensionDamping = max(0, suspensionDamping)
        self.radius = max(0.01, radius)
        self.width = max(0.01, width)
        self.inertia = max(0.001, inertia)
        self.angularDamping = max(0, angularDamping)
        self.maxSteerAngle = max(0, maxSteerAngle)
        self.maxBrakeTorque = max(0, maxBrakeTorque)
        self.maxHandBrakeTorque = max(0, maxHandBrakeTorque)
    }
}

public struct VehicleDifferentialConfiguration: Sendable, Equatable {
    public var leftWheel: Int
    public var rightWheel: Int
    public var differentialRatio: Float
    public var leftRightSplit: Float
    public var limitedSlipRatio: Float
    public var engineTorqueRatio: Float

    public init(
        leftWheel: Int,
        rightWheel: Int,
        differentialRatio: Float = 3.42,
        leftRightSplit: Float = 0.5,
        limitedSlipRatio: Float = 1.4,
        engineTorqueRatio: Float = 1
    ) {
        self.leftWheel = leftWheel
        self.rightWheel = rightWheel
        self.differentialRatio = max(0.001, differentialRatio)
        self.leftRightSplit = max(0, min(leftRightSplit, 1))
        self.limitedSlipRatio = max(1.0001, limitedSlipRatio)
        self.engineTorqueRatio = max(0, engineTorqueRatio)
    }
}

public struct VehicleAntiRollBarConfiguration: Sendable, Equatable {
    public var leftWheel: Int
    public var rightWheel: Int
    public var stiffness: Float

    public init(leftWheel: Int, rightWheel: Int, stiffness: Float = 1_000) {
        self.leftWheel = leftWheel
        self.rightWheel = rightWheel
        self.stiffness = max(0, stiffness)
    }
}

public struct VehicleEngineConfiguration: Sendable, Equatable {
    public var maxTorque: Float
    public var minRPM: Float
    public var maxRPM: Float
    public var inertia: Float
    public var angularDamping: Float

    public init(
        maxTorque: Float = 500,
        minRPM: Float = 1_000,
        maxRPM: Float = 6_000,
        inertia: Float = 0.5,
        angularDamping: Float = 0.2
    ) {
        self.maxTorque = max(0, maxTorque)
        self.minRPM = max(0, minRPM)
        self.maxRPM = max(self.minRPM, maxRPM)
        self.inertia = max(0.001, inertia)
        self.angularDamping = max(0, angularDamping)
    }
}

public struct VehicleTransmissionConfiguration: Sendable, Equatable {
    public var mode: VehicleTransmissionMode
    public var gearRatios: [Float]
    public var reverseGearRatios: [Float]
    public var switchTime: Float
    public var clutchReleaseTime: Float
    public var switchLatency: Float
    public var shiftUpRPM: Float
    public var shiftDownRPM: Float
    public var clutchStrength: Float

    public init(
        mode: VehicleTransmissionMode = .automatic,
        gearRatios: [Float] = [2.66, 1.78, 1.3, 1, 0.74],
        reverseGearRatios: [Float] = [-2.9],
        switchTime: Float = 0.5,
        clutchReleaseTime: Float = 0.3,
        switchLatency: Float = 0.5,
        shiftUpRPM: Float = 4_000,
        shiftDownRPM: Float = 2_000,
        clutchStrength: Float = 10
    ) {
        self.mode = mode
        self.gearRatios = gearRatios.isEmpty ? [1] : gearRatios
        self.reverseGearRatios = reverseGearRatios.isEmpty ? [-1] : reverseGearRatios
        self.switchTime = max(0, switchTime)
        self.clutchReleaseTime = max(0, clutchReleaseTime)
        self.switchLatency = max(0, switchLatency)
        self.shiftUpRPM = max(0, shiftUpRPM)
        self.shiftDownRPM = max(0, min(shiftDownRPM, self.shiftUpRPM))
        self.clutchStrength = max(0, clutchStrength)
    }
}

public enum VehicleControllerKind: UInt8, Sendable, Equatable, Codable, CaseIterable {
    case wheeled
    case tracked
    case motorcycle
}

public struct VehicleTrackConfiguration: Sendable, Equatable {
    public var drivenWheel: Int
    public var wheels: [Int]
    public var inertia: Float
    public var angularDamping: Float
    public var maxBrakeTorque: Float
    public var differentialRatio: Float

    public init(
        drivenWheel: Int,
        wheels: [Int],
        inertia: Float = 10,
        angularDamping: Float = 0.5,
        maxBrakeTorque: Float = 15_000,
        differentialRatio: Float = 6
    ) {
        self.drivenWheel = drivenWheel
        self.wheels = wheels
        self.inertia = max(0.001, inertia)
        self.angularDamping = max(0, angularDamping)
        self.maxBrakeTorque = max(0, maxBrakeTorque)
        self.differentialRatio = max(0.001, differentialRatio)
    }
}

public struct TrackedVehicleConfiguration: Sendable, Equatable {
    public var leftTrack: VehicleTrackConfiguration
    public var rightTrack: VehicleTrackConfiguration
    public var longitudinalFriction: Float
    public var lateralFriction: Float

    public init(
        leftTrack: VehicleTrackConfiguration,
        rightTrack: VehicleTrackConfiguration,
        longitudinalFriction: Float = 4,
        lateralFriction: Float = 2
    ) {
        self.leftTrack = leftTrack
        self.rightTrack = rightTrack
        self.longitudinalFriction = max(0, longitudinalFriction)
        self.lateralFriction = max(0, lateralFriction)
    }
}

public struct MotorcycleVehicleConfiguration: Sendable, Equatable {
    public var maxLeanAngle: Float
    public var leanSpringConstant: Float
    public var leanSpringDamping: Float
    public var leanSpringIntegrationCoefficient: Float
    public var leanSpringIntegrationCoefficientDecay: Float
    public var leanSmoothingFactor: Float
    public var isLeanControllerEnabled: Bool
    public var isLeanSteeringLimitEnabled: Bool

    public init(
        maxLeanAngle: Float = .pi / 4,
        leanSpringConstant: Float = 5_000,
        leanSpringDamping: Float = 1_000,
        leanSpringIntegrationCoefficient: Float = 0,
        leanSpringIntegrationCoefficientDecay: Float = 4,
        leanSmoothingFactor: Float = 0.8,
        isLeanControllerEnabled: Bool = true,
        isLeanSteeringLimitEnabled: Bool = true
    ) {
        self.maxLeanAngle = max(0, min(maxLeanAngle, .pi / 2))
        self.leanSpringConstant = max(0, leanSpringConstant)
        self.leanSpringDamping = max(0, leanSpringDamping)
        self.leanSpringIntegrationCoefficient = max(0, leanSpringIntegrationCoefficient)
        self.leanSpringIntegrationCoefficientDecay = max(0, leanSpringIntegrationCoefficientDecay)
        self.leanSmoothingFactor = max(0, min(leanSmoothingFactor, 1))
        self.isLeanControllerEnabled = isLeanControllerEnabled
        self.isLeanSteeringLimitEnabled = isLeanSteeringLimitEnabled
    }
}

public enum VehicleControllerConfiguration: Sendable, Equatable {
    case wheeled
    case tracked(TrackedVehicleConfiguration)
    case motorcycle(MotorcycleVehicleConfiguration)

    public var kind: VehicleControllerKind {
        switch self {
        case .wheeled: return .wheeled
        case .tracked: return .tracked
        case .motorcycle: return .motorcycle
        }
    }
}

/// A Jolt vehicle attached to the same entity's dynamic `RigidBody`.
public struct Vehicle: RuntimeComponent, Sendable, Equatable {
    public var controller: VehicleControllerConfiguration
    public var wheels: [VehicleWheelConfiguration]
    public var differentials: [VehicleDifferentialConfiguration]
    public var antiRollBars: [VehicleAntiRollBarConfiguration]
    public var engine: VehicleEngineConfiguration
    public var transmission: VehicleTransmissionConfiguration
    public var up: SIMD3<Float>
    public var forward: SIMD3<Float>
    public var maxPitchRollAngle: Float
    public var isEnabled: Bool

    public init(
        controller: VehicleControllerConfiguration = .wheeled,
        wheels: [VehicleWheelConfiguration] = Vehicle.defaultWheels,
        differentials: [VehicleDifferentialConfiguration] = [
            VehicleDifferentialConfiguration(leftWheel: 2, rightWheel: 3)
        ],
        antiRollBars: [VehicleAntiRollBarConfiguration] = [
            VehicleAntiRollBarConfiguration(leftWheel: 0, rightWheel: 1),
            VehicleAntiRollBarConfiguration(leftWheel: 2, rightWheel: 3),
        ],
        engine: VehicleEngineConfiguration = VehicleEngineConfiguration(),
        transmission: VehicleTransmissionConfiguration = VehicleTransmissionConfiguration(),
        up: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        forward: SIMD3<Float> = SIMD3<Float>(0, 0, 1),
        maxPitchRollAngle: Float = .pi,
        isEnabled: Bool = true
    ) {
        self.controller = controller
        self.wheels = wheels
        self.differentials = differentials
        self.antiRollBars = antiRollBars
        self.engine = engine
        self.transmission = transmission
        self.up = up
        self.forward = forward
        self.maxPitchRollAngle = max(0, min(maxPitchRollAngle, .pi))
        self.isEnabled = isEnabled
    }

    public static let defaultWheels: [VehicleWheelConfiguration] = [
        VehicleWheelConfiguration(position: SIMD3<Float>(0.9, -0.2, 1.4), maxSteerAngle: .pi / 4),
        VehicleWheelConfiguration(position: SIMD3<Float>(-0.9, -0.2, 1.4), maxSteerAngle: .pi / 4),
        VehicleWheelConfiguration(position: SIMD3<Float>(0.9, -0.2, -1.4), maxHandBrakeTorque: 4_000),
        VehicleWheelConfiguration(position: SIMD3<Float>(-0.9, -0.2, -1.4), maxHandBrakeTorque: 4_000),
    ]

    public static func tracked(
        engine: VehicleEngineConfiguration = VehicleEngineConfiguration(maxTorque: 1_500),
        transmission: VehicleTransmissionConfiguration = VehicleTransmissionConfiguration()
    ) -> Vehicle {
        let wheels = [
            VehicleWheelConfiguration(position: SIMD3<Float>(0.9, -0.25, 1.2), width: 0.35),
            VehicleWheelConfiguration(position: SIMD3<Float>(0.9, -0.25, 0), width: 0.35),
            VehicleWheelConfiguration(position: SIMD3<Float>(0.9, -0.25, -1.2), width: 0.35),
            VehicleWheelConfiguration(position: SIMD3<Float>(-0.9, -0.25, 1.2), width: 0.35),
            VehicleWheelConfiguration(position: SIMD3<Float>(-0.9, -0.25, 0), width: 0.35),
            VehicleWheelConfiguration(position: SIMD3<Float>(-0.9, -0.25, -1.2), width: 0.35),
        ]
        let tracked = TrackedVehicleConfiguration(
            leftTrack: VehicleTrackConfiguration(drivenWheel: 2, wheels: [0, 1, 2]),
            rightTrack: VehicleTrackConfiguration(drivenWheel: 5, wheels: [3, 4, 5])
        )
        return Vehicle(
            controller: .tracked(tracked),
            wheels: wheels,
            differentials: [],
            antiRollBars: [],
            engine: engine,
            transmission: transmission,
            maxPitchRollAngle: .pi / 3
        )
    }

    public static func motorcycle(
        configuration: MotorcycleVehicleConfiguration = MotorcycleVehicleConfiguration(),
        engine: VehicleEngineConfiguration = VehicleEngineConfiguration(
            maxTorque: 150, minRPM: 1_000, maxRPM: 10_000
        ),
        transmission: VehicleTransmissionConfiguration = VehicleTransmissionConfiguration(
            gearRatios: [2.27, 1.63, 1.3, 1.09, 0.96, 0.88],
            reverseGearRatios: [-4],
            shiftUpRPM: 8_000,
            shiftDownRPM: 2_000,
            clutchStrength: 2
        )
    ) -> Vehicle {
        let front = VehicleWheelConfiguration(
            position: SIMD3<Float>(0, -0.25, 0.75),
            suspensionDirection: SIMD3<Float>(0, -0.866_025_4, 0.5),
            steeringAxis: SIMD3<Float>(0, 0.866_025_4, -0.5),
            suspensionMinLength: 0.3,
            suspensionMaxLength: 0.5,
            suspensionFrequency: 1.5,
            radius: 0.31,
            width: 0.08,
            maxSteerAngle: .pi / 6,
            maxBrakeTorque: 500
        )
        let rear = VehicleWheelConfiguration(
            position: SIMD3<Float>(0, -0.25, -0.75),
            suspensionMinLength: 0.3,
            suspensionMaxLength: 0.5,
            suspensionFrequency: 2,
            radius: 0.31,
            width: 0.08,
            maxBrakeTorque: 250
        )
        return Vehicle(
            controller: .motorcycle(configuration),
            wheels: [front, rear],
            differentials: [
                VehicleDifferentialConfiguration(
                    leftWheel: -1,
                    rightWheel: 1,
                    differentialRatio: 4.825
                )
            ],
            antiRollBars: [],
            engine: engine,
            transmission: transmission,
            maxPitchRollAngle: .pi / 3
        )
    }
}

public struct VehicleCommand: Sendable, Equatable {
    public var throttle: Float
    public var steering: Float
    public var brake: Float
    public var handBrake: Float
    public var manualGear: Int?
    public var clutch: Float

    public init(
        throttle: Float = 0,
        steering: Float = 0,
        brake: Float = 0,
        handBrake: Float = 0,
        manualGear: Int? = nil,
        clutch: Float = 1
    ) {
        self.throttle = max(-1, min(throttle, 1))
        self.steering = max(-1, min(steering, 1))
        self.brake = max(0, min(brake, 1))
        self.handBrake = max(0, min(handBrake, 1))
        self.manualGear = manualGear
        self.clutch = max(0, min(clutch, 1))
    }
}

public struct VehicleCommandFrameResource: Sendable, Equatable {
    public var commands: [EntityID: VehicleCommand]

    public init(commands: [EntityID: VehicleCommand] = [:]) {
        self.commands = commands
    }

    public static let empty = VehicleCommandFrameResource()
}

public struct VehicleWheelState: Sendable, Equatable {
    public var index: Int
    public var worldPosition: SIMD3<Float>
    public var worldRotation: SIMD4<Float>
    public var angularVelocity: Float
    public var rotationAngle: Float
    public var steerAngle: Float
    public var suspensionLength: Float
    public var hasContact: Bool
    public var contactEntity: EntityID?
    public var contactPosition: SIMD3<Float>
    public var contactNormal: SIMD3<Float>

    public init(
        index: Int,
        worldPosition: SIMD3<Float> = .zero,
        worldRotation: SIMD4<Float> = SIMD4<Float>(0, 0, 0, 1),
        angularVelocity: Float = 0,
        rotationAngle: Float = 0,
        steerAngle: Float = 0,
        suspensionLength: Float = 0,
        hasContact: Bool = false,
        contactEntity: EntityID? = nil,
        contactPosition: SIMD3<Float> = .zero,
        contactNormal: SIMD3<Float> = .zero
    ) {
        self.index = index
        self.worldPosition = worldPosition
        self.worldRotation = worldRotation
        self.angularVelocity = angularVelocity
        self.rotationAngle = rotationAngle
        self.steerAngle = steerAngle
        self.suspensionLength = suspensionLength
        self.hasContact = hasContact
        self.contactEntity = contactEntity
        self.contactPosition = contactPosition
        self.contactNormal = contactNormal
    }
}

public struct VehicleState: Sendable, Equatable {
    public var entity: EntityID
    public var forwardSpeed: Float
    public var engineRPM: Float
    public var currentGear: Int
    public var clutchFriction: Float
    public var wheels: [VehicleWheelState]

    public init(
        entity: EntityID,
        forwardSpeed: Float = 0,
        engineRPM: Float = 0,
        currentGear: Int = 0,
        clutchFriction: Float = 0,
        wheels: [VehicleWheelState] = []
    ) {
        self.entity = entity
        self.forwardSpeed = forwardSpeed
        self.engineRPM = engineRPM
        self.currentGear = currentGear
        self.clutchFriction = clutchFriction
        self.wheels = wheels
    }
}

public struct VehicleStateFrameResource: Sendable, Equatable {
    public var states: [EntityID: VehicleState]

    public init(states: [EntityID: VehicleState] = [:]) {
        self.states = states
    }

    public static let empty = VehicleStateFrameResource()
}

public enum ClothBendType: UInt8, Sendable, Equatable, Codable, CaseIterable {
    case none
    case distance
    case dihedral
}

/// Grid topology authored for a Jolt soft-body cloth.
public struct Cloth: RuntimeComponent, Sendable, Equatable {
    public var gridSizeX: Int
    public var gridSizeZ: Int
    public var spacing: Float
    public var fixedVertexIndices: [Int]
    public var compliance: Float
    public var shearCompliance: Float
    public var bendCompliance: Float
    public var bendType: ClothBendType

    public init(
        gridSizeX: Int = 16,
        gridSizeZ: Int = 16,
        spacing: Float = 0.2,
        fixedVertexIndices: [Int] = [],
        compliance: Float = 1.0e-5,
        shearCompliance: Float = 1.0e-5,
        bendCompliance: Float = 1.0e-5,
        bendType: ClothBendType = .distance
    ) {
        self.gridSizeX = max(2, min(gridSizeX, 512))
        self.gridSizeZ = max(2, min(gridSizeZ, 512))
        self.spacing = max(0.001, spacing)
        let vertexCount = self.gridSizeX * self.gridSizeZ
        self.fixedVertexIndices = Array(Set(fixedVertexIndices.filter {
            $0 >= 0 && $0 < vertexCount
        })).sorted()
        self.compliance = max(0, compliance)
        self.shearCompliance = max(0, shearCompliance)
        self.bendCompliance = max(0, bendCompliance)
        self.bendType = bendType
    }

    public static func fixedTopEdge(
        gridSizeX: Int = 16,
        gridSizeZ: Int = 16,
        spacing: Float = 0.2
    ) -> Cloth {
        let width = max(2, min(gridSizeX, 512))
        return Cloth(
            gridSizeX: width,
            gridSizeZ: gridSizeZ,
            spacing: spacing,
            fixedVertexIndices: Array(0..<width)
        )
    }

    public var vertexCount: Int { gridSizeX * gridSizeZ }
    public var triangleIndexCount: Int { (gridSizeX - 1) * (gridSizeZ - 1) * 6 }

    public var triangleIndices: [UInt32] {
        var result: [UInt32] = []
        result.reserveCapacity(triangleIndexCount)
        for z in 0..<(gridSizeZ - 1) {
            for x in 0..<(gridSizeX - 1) {
                let topLeft = UInt32(x + z * gridSizeX)
                let bottomLeft = UInt32(x + (z + 1) * gridSizeX)
                let bottomRight = UInt32(x + 1 + (z + 1) * gridSizeX)
                let topRight = UInt32(x + 1 + z * gridSizeX)
                result.append(contentsOf: [topLeft, bottomLeft, bottomRight,
                                           topLeft, bottomRight, topRight])
            }
        }
        return result
    }
}

/// Simulation and collision settings shared by deformable assets.
/// The first M6 slice supports `Cloth`; volumetric soft-body assets use the same
/// component and will be added without changing the streamed state format.
public struct SoftBody: RuntimeComponent, Sendable, Equatable {
    public var vertexMass: Float
    public var pressure: Float
    public var linearDamping: Float
    public var friction: Float
    public var restitution: Float
    public var gravityScale: Float
    public var vertexRadius: Float
    public var solverIterations: Int
    public var maxLinearVelocity: Float
    public var layerID: UInt16
    public var layerMask: UInt16
    public var allowSleep: Bool
    public var facesDoubleSided: Bool
    public var selfCollision: Bool
    public var isEnabled: Bool

    public init(
        vertexMass: Float = 1,
        pressure: Float = 0,
        linearDamping: Float = 0.1,
        friction: Float = 0.2,
        restitution: Float = 0,
        gravityScale: Float = 1,
        vertexRadius: Float = 0.02,
        solverIterations: Int = 5,
        maxLinearVelocity: Float = 500,
        layerID: UInt16 = 0,
        layerMask: UInt16 = .max,
        allowSleep: Bool = true,
        facesDoubleSided: Bool = true,
        selfCollision: Bool = false,
        isEnabled: Bool = true
    ) {
        self.vertexMass = max(0.0001, vertexMass)
        self.pressure = max(0, pressure)
        self.linearDamping = max(0, linearDamping)
        self.friction = max(0, friction)
        self.restitution = max(0, min(restitution, 1))
        self.gravityScale = gravityScale
        self.vertexRadius = max(0, vertexRadius)
        self.solverIterations = max(1, min(solverIterations, 128))
        self.maxLinearVelocity = max(0, maxLinearVelocity)
        self.layerID = layerID
        self.layerMask = layerMask
        self.allowSleep = allowSleep
        self.facesDoubleSided = facesDoubleSided
        self.selfCollision = selfCollision
        self.isEnabled = isEnabled
    }
}

/// Deformed vertices are streamed independently from ordinary ECS transforms.
public struct SoftBodyMeshState: Sendable, Equatable {
    public var entity: EntityID
    public var positions: [SIMD3<Float>]
    public var triangleIndices: [UInt32]
    public var isSleeping: Bool

    public init(
        entity: EntityID,
        positions: [SIMD3<Float>] = [],
        triangleIndices: [UInt32] = [],
        isSleeping: Bool = false
    ) {
        self.entity = entity
        self.positions = positions
        self.triangleIndices = triangleIndices
        self.isSleeping = isSleeping
    }
}

public struct SoftBodyStateFrameResource: Sendable, Equatable {
    public var states: [EntityID: SoftBodyMeshState]
    public var vertexCount: Int

    public init(states: [EntityID: SoftBodyMeshState] = [:]) {
        self.states = states
        vertexCount = states.values.reduce(0) { $0 + $1.positions.count }
    }

    public static let empty = SoftBodyStateFrameResource()
}

public enum PhysicsJointKind: String, Sendable, Equatable {
    case pointToPoint
    case hinge
    case fixed
    case slider
    case distance
    case cone
    case sixDOF
}

public struct PhysicsJointSpring: Sendable, Equatable {
    public var frequency: Float
    public var damping: Float

    public init(frequency: Float = 0, damping: Float = 0) {
        self.frequency = max(0, frequency)
        self.damping = max(0, damping)
    }
}

public enum PhysicsJointMotorMode: String, Sendable, Equatable {
    case disabled
    case position
    case velocity
}

public struct PhysicsJointMotor: Sendable, Equatable {
    public var mode: PhysicsJointMotorMode
    public var targetPosition: Float
    public var targetVelocity: Float
    public var maxForce: Float

    public init(
        mode: PhysicsJointMotorMode = .disabled,
        targetPosition: Float = 0,
        targetVelocity: Float = 0,
        maxForce: Float = .greatestFiniteMagnitude
    ) {
        self.mode = mode
        self.targetPosition = targetPosition
        self.targetVelocity = targetVelocity
        self.maxForce = max(0, maxForce)
    }
}

public struct DistanceJointConfiguration: Sendable, Equatable {
    public var minimumDistance: Float
    public var maximumDistance: Float
    public var spring: PhysicsJointSpring

    public init(minimumDistance: Float = 0, maximumDistance: Float = 0,
                spring: PhysicsJointSpring = PhysicsJointSpring()) {
        self.minimumDistance = max(0, minimumDistance)
        self.maximumDistance = max(self.minimumDistance, maximumDistance)
        self.spring = spring
    }
}

public struct HingeJointConfiguration: Sendable, Equatable {
    public var axisA: SIMD3<Float>
    public var axisB: SIMD3<Float>
    public var minimumAngle: Float
    public var maximumAngle: Float
    public var motor: PhysicsJointMotor
    public var spring: PhysicsJointSpring

    public init(
        axisA: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        axisB: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        minimumAngle: Float = 0,
        maximumAngle: Float = 0,
        motor: PhysicsJointMotor = PhysicsJointMotor(),
        spring: PhysicsJointSpring = PhysicsJointSpring()
    ) {
        self.axisA = axisA
        self.axisB = axisB
        self.minimumAngle = min(minimumAngle, maximumAngle)
        self.maximumAngle = max(minimumAngle, maximumAngle)
        self.motor = motor
        self.spring = spring
    }
}

public struct SliderJointConfiguration: Sendable, Equatable {
    public var axisA: SIMD3<Float>
    public var axisB: SIMD3<Float>
    public var minimumDistance: Float
    public var maximumDistance: Float
    public var motor: PhysicsJointMotor
    public var spring: PhysicsJointSpring

    public init(
        axisA: SIMD3<Float> = SIMD3<Float>(1, 0, 0),
        axisB: SIMD3<Float> = SIMD3<Float>(1, 0, 0),
        minimumDistance: Float = 0,
        maximumDistance: Float = 0,
        motor: PhysicsJointMotor = PhysicsJointMotor(),
        spring: PhysicsJointSpring = PhysicsJointSpring()
    ) {
        self.axisA = axisA
        self.axisB = axisB
        self.minimumDistance = min(minimumDistance, maximumDistance)
        self.maximumDistance = max(minimumDistance, maximumDistance)
        self.motor = motor
        self.spring = spring
    }
}

public struct ConeJointConfiguration: Sendable, Equatable {
    public var twistAxisA: SIMD3<Float>
    public var twistAxisB: SIMD3<Float>
    public var halfConeAngle: Float
    public var minimumTwistAngle: Float
    public var maximumTwistAngle: Float
    public var spring: PhysicsJointSpring

    public init(
        twistAxisA: SIMD3<Float> = SIMD3<Float>(1, 0, 0),
        twistAxisB: SIMD3<Float> = SIMD3<Float>(1, 0, 0),
        halfConeAngle: Float = .pi / 4,
        minimumTwistAngle: Float = -.pi,
        maximumTwistAngle: Float = .pi,
        spring: PhysicsJointSpring = PhysicsJointSpring()
    ) {
        self.twistAxisA = twistAxisA
        self.twistAxisB = twistAxisB
        self.halfConeAngle = max(0, halfConeAngle)
        self.minimumTwistAngle = min(minimumTwistAngle, maximumTwistAngle)
        self.maximumTwistAngle = max(minimumTwistAngle, maximumTwistAngle)
        self.spring = spring
    }
}

public struct SixDOFJointConfiguration: Sendable, Equatable {
    public var axisA: SIMD3<Float>
    public var axisB: SIMD3<Float>
    public var linearMinimum: SIMD3<Float>
    public var linearMaximum: SIMD3<Float>
    public var angularMinimum: SIMD3<Float>
    public var angularMaximum: SIMD3<Float>
    public var linearMotor: PhysicsJointMotor
    public var angularMotor: PhysicsJointMotor
    public var spring: PhysicsJointSpring

    public init(
        axisA: SIMD3<Float> = SIMD3<Float>(1, 0, 0),
        axisB: SIMD3<Float> = SIMD3<Float>(1, 0, 0),
        linearMinimum: SIMD3<Float> = .zero,
        linearMaximum: SIMD3<Float> = .zero,
        angularMinimum: SIMD3<Float> = .zero,
        angularMaximum: SIMD3<Float> = .zero,
        linearMotor: PhysicsJointMotor = PhysicsJointMotor(),
        angularMotor: PhysicsJointMotor = PhysicsJointMotor(),
        spring: PhysicsJointSpring = PhysicsJointSpring()
    ) {
        self.axisA = axisA
        self.axisB = axisB
        self.linearMinimum = simd_min(linearMinimum, linearMaximum)
        self.linearMaximum = simd_max(linearMinimum, linearMaximum)
        self.angularMinimum = simd_min(angularMinimum, angularMaximum)
        self.angularMaximum = simd_max(angularMinimum, angularMaximum)
        self.linearMotor = linearMotor
        self.angularMotor = angularMotor
        self.spring = spring
    }
}

public enum PhysicsJointConfiguration: Sendable, Equatable {
    case point
    case fixed(axisA: SIMD3<Float>, axisB: SIMD3<Float>)
    case distance(DistanceJointConfiguration)
    case hinge(HingeJointConfiguration)
    case slider(SliderJointConfiguration)
    case cone(ConeJointConfiguration)
    case sixDOF(SixDOFJointConfiguration)

    public var kind: PhysicsJointKind {
        switch self {
        case .point: return .pointToPoint
        case .fixed: return .fixed
        case .distance: return .distance
        case .hinge: return .hinge
        case .slider: return .slider
        case .cone: return .cone
        case .sixDOF: return .sixDOF
        }
    }
}

public struct PhysicsJoint: RuntimeComponent, Sendable, Equatable {
    public var configuration: PhysicsJointConfiguration
    public var entityA: EntityID
    public var entityB: EntityID
    public var pivotA: SIMD3<Float>
    public var pivotB: SIMD3<Float>
    public var isEnabled: Bool
    public var breakForce: Float
    public var breakTorque: Float

    public init(
        configuration: PhysicsJointConfiguration = .point,
        entityA: EntityID,
        entityB: EntityID,
        pivotA: SIMD3<Float> = .zero,
        pivotB: SIMD3<Float> = .zero,
        isEnabled: Bool = true,
        breakForce: Float = .greatestFiniteMagnitude,
        breakTorque: Float = .greatestFiniteMagnitude
    ) {
        self.configuration = configuration
        self.entityA = entityA
        self.entityB = entityB
        self.pivotA = pivotA
        self.pivotB = pivotB
        self.isEnabled = isEnabled
        self.breakForce = max(0, breakForce)
        self.breakTorque = max(0, breakTorque)
    }

    /// Compatibility initializer for Physics v1 callers. New code should use
    /// the typed `configuration` initializer above.
    public init(
        constraintType: PhysicsJointKind = .pointToPoint,
        entityA: EntityID,
        entityB: EntityID,
        pivotA: SIMD3<Float> = .zero,
        pivotB: SIMD3<Float> = .zero,
        axisA: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        axisB: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        minLimit: Float = 0,
        maxLimit: Float = 0,
        isEnabled: Bool = true,
        breakForce: Float = .greatestFiniteMagnitude,
        breakTorque: Float = .greatestFiniteMagnitude
    ) {
        switch constraintType {
        case .pointToPoint:
            configuration = .point
        case .fixed:
            configuration = .fixed(axisA: axisA, axisB: axisB)
        case .distance:
            configuration = .distance(DistanceJointConfiguration(
                minimumDistance: minLimit, maximumDistance: maxLimit))
        case .hinge:
            configuration = .hinge(HingeJointConfiguration(
                axisA: axisA, axisB: axisB,
                minimumAngle: minLimit, maximumAngle: maxLimit))
        case .slider:
            configuration = .slider(SliderJointConfiguration(
                axisA: axisA, axisB: axisB,
                minimumDistance: minLimit, maximumDistance: maxLimit))
        case .cone:
            configuration = .cone(ConeJointConfiguration(
                twistAxisA: axisA, twistAxisB: axisB,
                minimumTwistAngle: minLimit, maximumTwistAngle: maxLimit))
        case .sixDOF:
            configuration = .sixDOF(SixDOFJointConfiguration(axisA: axisA, axisB: axisB))
        }
        self.entityA = entityA
        self.entityB = entityB
        self.pivotA = pivotA
        self.pivotB = pivotB
        self.isEnabled = isEnabled
        self.breakForce = max(0, breakForce)
        self.breakTorque = max(0, breakTorque)
    }

    public var constraintType: PhysicsJointKind { configuration.kind }

    public var axisA: SIMD3<Float> {
        get { axes.0 }
        set { setAxes(newValue, axes.1) }
    }

    public var axisB: SIMD3<Float> {
        get { axes.1 }
        set { setAxes(axes.0, newValue) }
    }

    public var minLimit: Float {
        get { scalarLimits.0 }
        set { setScalarLimits(newValue, scalarLimits.1) }
    }

    public var maxLimit: Float {
        get { scalarLimits.1 }
        set { setScalarLimits(scalarLimits.0, newValue) }
    }

    private var axes: (SIMD3<Float>, SIMD3<Float>) {
        switch configuration {
        case .point, .distance: return (SIMD3<Float>(0, 1, 0), SIMD3<Float>(0, 1, 0))
        case let .fixed(a, b): return (a, b)
        case let .hinge(value): return (value.axisA, value.axisB)
        case let .slider(value): return (value.axisA, value.axisB)
        case let .cone(value): return (value.twistAxisA, value.twistAxisB)
        case let .sixDOF(value): return (value.axisA, value.axisB)
        }
    }

    private var scalarLimits: (Float, Float) {
        switch configuration {
        case let .distance(value): return (value.minimumDistance, value.maximumDistance)
        case let .hinge(value): return (value.minimumAngle, value.maximumAngle)
        case let .slider(value): return (value.minimumDistance, value.maximumDistance)
        case let .cone(value): return (value.minimumTwistAngle, value.maximumTwistAngle)
        default: return (0, 0)
        }
    }

    private mutating func setAxes(_ axisA: SIMD3<Float>, _ axisB: SIMD3<Float>) {
        switch configuration {
        case .point, .distance: break
        case .fixed: configuration = .fixed(axisA: axisA, axisB: axisB)
        case var .hinge(value): value.axisA = axisA; value.axisB = axisB; configuration = .hinge(value)
        case var .slider(value): value.axisA = axisA; value.axisB = axisB; configuration = .slider(value)
        case var .cone(value): value.twistAxisA = axisA; value.twistAxisB = axisB; configuration = .cone(value)
        case var .sixDOF(value): value.axisA = axisA; value.axisB = axisB; configuration = .sixDOF(value)
        }
    }

    private mutating func setScalarLimits(_ minimum: Float, _ maximum: Float) {
        switch configuration {
        case var .distance(value):
            value.minimumDistance = minimum; value.maximumDistance = maximum; configuration = .distance(value)
        case var .hinge(value):
            value.minimumAngle = minimum; value.maximumAngle = maximum; configuration = .hinge(value)
        case var .slider(value):
            value.minimumDistance = minimum; value.maximumDistance = maximum; configuration = .slider(value)
        case var .cone(value):
            value.minimumTwistAngle = minimum; value.maximumTwistAngle = maximum; configuration = .cone(value)
        default: break
        }
    }
}

public typealias ConstraintType = PhysicsJointKind

public typealias Constraint = PhysicsJoint

public enum RagdollMode: String, Sendable, Equatable {
    case animated
    case simulated
    case blended
}

/// Maps one rendered skin palette entry to a physics-body entity. `bodyFromPalette`
/// converts the palette-space bone transform to the desired rigid-body transform.
public struct RagdollBoneMapping: Sendable, Equatable {
    public var boneName: String
    public var paletteIndex: Int
    public var bodyEntity: EntityID
    public var jointEntity: EntityID?
    public var bodyFromPalette: simd_float4x4
    public var simulatedMotionType: RigidBodyMotionType
    public var isSimulationEnabled: Bool
    public var blendWeight: Float

    public init(
        boneName: String,
        paletteIndex: Int,
        bodyEntity: EntityID,
        jointEntity: EntityID? = nil,
        bodyFromPalette: simd_float4x4 = matrix_identity_float4x4,
        simulatedMotionType: RigidBodyMotionType = .dynamic,
        isSimulationEnabled: Bool = true,
        blendWeight: Float = 1
    ) {
        self.boneName = boneName
        self.paletteIndex = max(0, paletteIndex)
        self.bodyEntity = bodyEntity
        self.jointEntity = jointEntity
        self.bodyFromPalette = bodyFromPalette
        self.simulatedMotionType = simulatedMotionType
        self.isSimulationEnabled = isSimulationEnabled
        self.blendWeight = max(0, min(blendWeight, 1))
    }
}

/// Authored ragdoll mapping stored on the skinned-mesh/root entity.
public struct Ragdoll: RuntimeComponent, Sendable, Equatable {
    public var mode: RagdollMode
    public var blendWeight: Float
    public var isEnabled: Bool
    public var bones: [RagdollBoneMapping]

    public init(
        mode: RagdollMode = .animated,
        blendWeight: Float = 1,
        isEnabled: Bool = true,
        bones: [RagdollBoneMapping] = []
    ) {
        self.mode = mode
        self.blendWeight = max(0, min(blendWeight, 1))
        self.isEnabled = isEnabled
        self.bones = bones.sorted {
            if $0.paletteIndex != $1.paletteIndex { return $0.paletteIndex < $1.paletteIndex }
            return $0.bodyEntity.rawValue < $1.bodyEntity.rawValue
        }
    }
}

public struct RagdollBoneState: Sendable, Equatable {
    public var boneName: String
    public var paletteIndex: Int
    public var bodyEntity: EntityID
    public var worldTransform: WorldTransform
    public var isSimulated: Bool

    public init(boneName: String, paletteIndex: Int, bodyEntity: EntityID,
                worldTransform: WorldTransform, isSimulated: Bool) {
        self.boneName = boneName
        self.paletteIndex = paletteIndex
        self.bodyEntity = bodyEntity
        self.worldTransform = worldTransform
        self.isSimulated = isSimulated
    }
}

public struct RagdollState: Sendable, Equatable {
    public var entity: EntityID
    public var mode: RagdollMode
    public var bones: [RagdollBoneState]

    public init(entity: EntityID, mode: RagdollMode, bones: [RagdollBoneState]) {
        self.entity = entity
        self.mode = mode
        self.bones = bones
    }
}

public struct RagdollStateFrameResource: Sendable, Equatable {
    public var states: [EntityID: RagdollState]

    public init(states: [EntityID: RagdollState] = [:]) {
        self.states = states
    }

    public static let empty = RagdollStateFrameResource()
}

public struct PhysicsCapacitySettings: Sendable, Equatable, Codable {
    public var maxBodies: Int
    public var bodyMutexCount: Int
    public var maxBodyPairs: Int
    public var maxContactConstraints: Int
    public var tempAllocatorBytes: Int
    /// Zero selects the platform default: the available logical core count minus one.
    public var workerThreadCount: Int

    public init(
        maxBodies: Int = 65_536,
        bodyMutexCount: Int = 0,
        maxBodyPairs: Int = 65_536,
        maxContactConstraints: Int = 10_240,
        tempAllocatorBytes: Int = 10 * 1_024 * 1_024,
        workerThreadCount: Int = 0
    ) {
        self.maxBodies = min(Int(UInt32.max), max(1, maxBodies))
        self.bodyMutexCount = min(Int(UInt32.max), max(0, bodyMutexCount))
        self.maxBodyPairs = min(Int(UInt32.max), max(1, maxBodyPairs))
        self.maxContactConstraints = min(Int(UInt32.max), max(1, maxContactConstraints))
        self.tempAllocatorBytes = min(Int(UInt32.max), max(1_024 * 1_024, tempAllocatorBytes))
        self.workerThreadCount = min(1_024, max(0, workerThreadCount))
    }

    private enum CodingKeys: String, CodingKey {
        case maxBodies
        case bodyMutexCount
        case maxBodyPairs
        case maxContactConstraints
        case tempAllocatorBytes
        case workerThreadCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PhysicsCapacitySettings()
        self.init(
            maxBodies: try values.decodeIfPresent(Int.self, forKey: .maxBodies) ?? defaults.maxBodies,
            bodyMutexCount: try values.decodeIfPresent(Int.self, forKey: .bodyMutexCount) ?? defaults.bodyMutexCount,
            maxBodyPairs: try values.decodeIfPresent(Int.self, forKey: .maxBodyPairs) ?? defaults.maxBodyPairs,
            maxContactConstraints: try values.decodeIfPresent(Int.self, forKey: .maxContactConstraints)
                ?? defaults.maxContactConstraints,
            tempAllocatorBytes: try values.decodeIfPresent(Int.self, forKey: .tempAllocatorBytes)
                ?? defaults.tempAllocatorBytes,
            workerThreadCount: try values.decodeIfPresent(Int.self, forKey: .workerThreadCount)
                ?? defaults.workerThreadCount
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(maxBodies, forKey: .maxBodies)
        try values.encode(bodyMutexCount, forKey: .bodyMutexCount)
        try values.encode(maxBodyPairs, forKey: .maxBodyPairs)
        try values.encode(maxContactConstraints, forKey: .maxContactConstraints)
        try values.encode(tempAllocatorBytes, forKey: .tempAllocatorBytes)
        try values.encode(workerThreadCount, forKey: .workerThreadCount)
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
    public var capacity: PhysicsCapacitySettings

    public init(
        simulationMode: PhysicsSimulationMode = .off,
        backendKind: PhysicsBackendKind = .jolt,
        gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0),
        fixedTimeStepSeconds: Double = 1.0 / 60.0,
        maxSubstepsPerFrame: Int = 4,
        allowSleep: Bool = true,
        collisionSteps: Int = 1,
        capacity: PhysicsCapacitySettings = PhysicsCapacitySettings()
    ) {
        self.simulationMode = simulationMode
        self.backendKind = backendKind
        self.gravity = gravity
        self.fixedTimeStepSeconds = max(0.000_001, fixedTimeStepSeconds)
        self.maxSubstepsPerFrame = max(1, maxSubstepsPerFrame)
        self.allowSleep = allowSleep
        self.collisionSteps = max(1, collisionSteps)
        self.capacity = PhysicsCapacitySettings(
            maxBodies: capacity.maxBodies,
            bodyMutexCount: capacity.bodyMutexCount,
            maxBodyPairs: capacity.maxBodyPairs,
            maxContactConstraints: capacity.maxContactConstraints,
            tempAllocatorBytes: capacity.tempAllocatorBytes,
            workerThreadCount: capacity.workerThreadCount
        )
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
    public var softBodyCount: Int
    public var softBodyVertexCount: Int
    public var constraintCount: Int
    public var contactCount: Int
    public var writebackCount: Int
    public var simulatedSteps: Int
    public var simulatedSeconds: Double
    public var synchronizedBodyCount: Int
    public var synchronizedSoftBodyCount: Int
    public var synchronizedConstraintCount: Int
    public var activeBodyCount: Int
    public var activeSoftBodyCount: Int
    public var droppedStepCount: Int
    public var synchronizationNanoseconds: UInt64
    public var stepNanoseconds: UInt64
    public var lastError: PhysicsBackendError?

    public init(
        backendIdentifier: String = "none",
        bodyCount: Int = 0,
        softBodyCount: Int = 0,
        softBodyVertexCount: Int = 0,
        constraintCount: Int = 0,
        contactCount: Int = 0,
        writebackCount: Int = 0,
        simulatedSteps: Int = 0,
        simulatedSeconds: Double = 0,
        synchronizedBodyCount: Int = 0,
        synchronizedSoftBodyCount: Int = 0,
        synchronizedConstraintCount: Int = 0,
        activeBodyCount: Int = 0,
        activeSoftBodyCount: Int = 0,
        droppedStepCount: Int = 0,
        synchronizationNanoseconds: UInt64 = 0,
        stepNanoseconds: UInt64 = 0,
        lastError: PhysicsBackendError? = nil
    ) {
        self.backendIdentifier = backendIdentifier
        self.bodyCount = bodyCount
        self.softBodyCount = softBodyCount
        self.softBodyVertexCount = softBodyVertexCount
        self.constraintCount = constraintCount
        self.contactCount = contactCount
        self.writebackCount = writebackCount
        self.simulatedSteps = simulatedSteps
        self.simulatedSeconds = simulatedSeconds
        self.synchronizedBodyCount = synchronizedBodyCount
        self.synchronizedSoftBodyCount = synchronizedSoftBodyCount
        self.synchronizedConstraintCount = synchronizedConstraintCount
        self.activeBodyCount = activeBodyCount
        self.activeSoftBodyCount = activeSoftBodyCount
        self.droppedStepCount = droppedStepCount
        self.synchronizationNanoseconds = synchronizationNanoseconds
        self.stepNanoseconds = stepNanoseconds
        self.lastError = lastError
    }
}

public struct PhysicsStateHashFrameResource: Sendable, Equatable {
    public var simulatedStep: Int
    public var hash: UInt64

    public init(simulatedStep: Int = 0, hash: UInt64 = 0) {
        self.simulatedStep = simulatedStep
        self.hash = hash
    }

    public static let empty = PhysicsStateHashFrameResource()
}

public struct PhysicsRecordedBodyCommand: Sendable, Equatable {
    public var entity: EntityID
    public var force: SIMD3<Float>
    public var torque: SIMD3<Float>
    public var linearImpulse: SIMD3<Float>
    public var angularImpulse: SIMD3<Float>
    public var wake: Bool

    public init(
        entity: EntityID,
        force: SIMD3<Float> = .zero,
        torque: SIMD3<Float> = .zero,
        linearImpulse: SIMD3<Float> = .zero,
        angularImpulse: SIMD3<Float> = .zero,
        wake: Bool = true
    ) {
        self.entity = entity
        self.force = force
        self.torque = torque
        self.linearImpulse = linearImpulse
        self.angularImpulse = angularImpulse
        self.wake = wake
    }
}

public struct PhysicsRecordedCharacterCommand: Sendable, Equatable {
    public var entity: EntityID
    public var command: CharacterCommand

    public init(entity: EntityID, command: CharacterCommand) {
        self.entity = entity
        self.command = command
    }
}

public struct PhysicsRecordedVehicleCommand: Sendable, Equatable {
    public var entity: EntityID
    public var command: VehicleCommand

    public init(entity: EntityID, command: VehicleCommand) {
        self.entity = entity
        self.command = command
    }
}

public struct PhysicsCommandFrame: Sendable, Equatable {
    public var deltaTimeSeconds: Double
    public var settings: PhysicsSettingsResource
    public var bodyCommands: [PhysicsRecordedBodyCommand]
    public var characterCommands: [PhysicsRecordedCharacterCommand]
    public var vehicleCommands: [PhysicsRecordedVehicleCommand]
    public var expectedSimulatedStep: Int
    public var expectedStateHash: UInt64

    public init(
        deltaTimeSeconds: Double,
        settings: PhysicsSettingsResource,
        bodyCommands: [PhysicsRecordedBodyCommand] = [],
        characterCommands: [PhysicsRecordedCharacterCommand] = [],
        vehicleCommands: [PhysicsRecordedVehicleCommand] = [],
        expectedSimulatedStep: Int,
        expectedStateHash: UInt64
    ) {
        self.deltaTimeSeconds = max(0, deltaTimeSeconds)
        self.settings = settings
        self.bodyCommands = bodyCommands.sorted { $0.entity.rawValue < $1.entity.rawValue }
        self.characterCommands = characterCommands.sorted { $0.entity.rawValue < $1.entity.rawValue }
        self.vehicleCommands = vehicleCommands.sorted { $0.entity.rawValue < $1.entity.rawValue }
        self.expectedSimulatedStep = expectedSimulatedStep
        self.expectedStateHash = expectedStateHash
    }
}

public struct PhysicsCommandTape: Sendable, Equatable {
    public var frames: [PhysicsCommandFrame]

    public init(frames: [PhysicsCommandFrame] = []) {
        self.frames = frames
    }
}

public struct PhysicsCommandRecordingResource: Sendable, Equatable {
    public var isRecording: Bool
    public var maxFrames: Int
    public var frames: [PhysicsCommandFrame]

    public init(isRecording: Bool = false, maxFrames: Int = 36_000, frames: [PhysicsCommandFrame] = []) {
        self.isRecording = isRecording
        self.maxFrames = max(1, maxFrames)
        self.frames = Array(frames.prefix(max(1, maxFrames)))
    }

    public static let inactive = PhysicsCommandRecordingResource()
}

public struct PhysicsReplayMismatch: Sendable, Equatable {
    public var frameIndex: Int
    public var expectedSimulatedStep: Int
    public var actualSimulatedStep: Int
    public var expectedStateHash: UInt64
    public var actualStateHash: UInt64

    public init(
        frameIndex: Int,
        expectedSimulatedStep: Int,
        actualSimulatedStep: Int,
        expectedStateHash: UInt64,
        actualStateHash: UInt64
    ) {
        self.frameIndex = frameIndex
        self.expectedSimulatedStep = expectedSimulatedStep
        self.actualSimulatedStep = actualSimulatedStep
        self.expectedStateHash = expectedStateHash
        self.actualStateHash = actualStateHash
    }
}

public struct PhysicsReplayReport: Sendable, Equatable {
    public var replayedFrameCount: Int
    public var checkpointHashes: [UInt64]
    public var mismatches: [PhysicsReplayMismatch]

    public init(
        replayedFrameCount: Int = 0,
        checkpointHashes: [UInt64] = [],
        mismatches: [PhysicsReplayMismatch] = []
    ) {
        self.replayedFrameCount = replayedFrameCount
        self.checkpointHashes = checkpointHashes
        self.mismatches = mismatches
    }

    public var isDeterministic: Bool { mismatches.isEmpty }
}

struct PhysicsCommandReplayControlResource: Sendable, Equatable {
    var isReplaying: Bool = false
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
    public var minimumLimit: Float
    public var maximumLimit: Float
    public var breakForce: Float
    public var breakTorque: Float
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
        minimumLimit = constraint.minLimit
        maximumLimit = constraint.maxLimit
        breakForce = constraint.breakForce
        breakTorque = constraint.breakTorque
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
    public var subShapeIDA: UInt32
    public var subShapeIDB: UInt32
    public var kind: PhysicsContactEventKind
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var penetrationDepth: Float
    public var relativeVelocity: SIMD3<Float>
    public var impulse: Float

    public init(
        entityA: EntityID,
        entityB: EntityID,
        subShapeIDA: UInt32 = 0,
        subShapeIDB: UInt32 = 0,
        kind: PhysicsContactEventKind,
        position: SIMD3<Float> = .zero,
        normal: SIMD3<Float> = .zero,
        penetrationDepth: Float = 0,
        relativeVelocity: SIMD3<Float> = .zero,
        impulse: Float = 0
    ) {
        self.entityA = entityA
        self.entityB = entityB
        self.subShapeIDA = subShapeIDA
        self.subShapeIDB = subShapeIDB
        self.kind = kind
        self.position = position
        self.normal = normal
        self.penetrationDepth = penetrationDepth
        self.relativeVelocity = relativeVelocity
        self.impulse = impulse
    }
}

public struct PhysicsEventFrameResource: Sendable, Equatable {
    public var contacts: [PhysicsContactEvent]
    public var triggers: [TriggerEvent]
    public var jointBreaks: [PhysicsJointBreakEvent]
    public var didOverflow: Bool

    public init(
        contacts: [PhysicsContactEvent] = [],
        triggers: [TriggerEvent] = [],
        jointBreaks: [PhysicsJointBreakEvent] = [],
        didOverflow: Bool = false
    ) {
        self.contacts = contacts
        self.triggers = triggers
        self.jointBreaks = jointBreaks
        self.didOverflow = didOverflow
    }

    public static let empty = PhysicsEventFrameResource()
}

public struct PhysicsJointBreakEvent: Sendable, Equatable {
    public var jointEntity: EntityID
    public var entityA: EntityID
    public var entityB: EntityID
    public var force: Float
    public var torque: Float

    public init(jointEntity: EntityID, entityA: EntityID, entityB: EntityID,
                force: Float, torque: Float) {
        self.jointEntity = jointEntity
        self.entityA = entityA
        self.entityB = entityB
        self.force = force
        self.torque = torque
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
    /// Legacy single-entity exclusion. New code can use `ignoredEntities` for
    /// self hierarchies and other multi-body exclusions.
    public var excludeEntity: EntityID?
    public var ignoredEntities: Set<EntityID>
    public var includeTriggers: Bool
    public var layerID: UInt16?
    public var layerMask: UInt16

    public init(
        excludeEntity: EntityID? = nil,
        ignoredEntities: Set<EntityID> = [],
        includeTriggers: Bool = false,
        layerID: UInt16? = nil,
        layerMask: UInt16 = .max
    ) {
        self.excludeEntity = excludeEntity
        self.ignoredEntities = ignoredEntities
        self.includeTriggers = includeTriggers
        self.layerID = layerID
        self.layerMask = layerMask
    }

    public var excludedEntities: Set<EntityID> {
        guard let excludeEntity else { return ignoredEntities }
        return ignoredEntities.union([excludeEntity])
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
    public var subShapeID: UInt32
    public var distance: Float
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(entity: EntityID,
                subShapeID: UInt32 = 0,
                distance: Float,
                position: SIMD3<Float>,
                normal: SIMD3<Float>,
                bounds: SpatialAABB,
                isTrigger: Bool) {
        self.entity = entity
        self.subShapeID = subShapeID
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
    public var subShapeID: UInt32
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(entity: EntityID, subShapeID: UInt32 = 0, bounds: SpatialAABB, isTrigger: Bool) {
        self.entity = entity
        self.subShapeID = subShapeID
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
    public var subShapeID: UInt32
    public var fraction: Float
    public var distance: Float
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(entity: EntityID,
                subShapeID: UInt32 = 0,
                fraction: Float,
                distance: Float,
                position: SIMD3<Float>,
                normal: SIMD3<Float>,
                bounds: SpatialAABB,
                isTrigger: Bool) {
        self.entity = entity
        self.subShapeID = subShapeID
        self.fraction = fraction
        self.distance = distance
        self.position = position
        self.normal = normal
        self.bounds = bounds
        self.isTrigger = isTrigger
    }
}

public enum PhysicsQueryResultMode: Sendable, Equatable {
    case nearest
    case all
}

public struct PhysicsQueryOptions: Sendable, Equatable {
    public var filter: PhysicsQueryFilter
    public var resultMode: PhysicsQueryResultMode
    public var maxHits: Int

    public init(
        filter: PhysicsQueryFilter = PhysicsQueryFilter(),
        resultMode: PhysicsQueryResultMode = .nearest,
        maxHits: Int = .max
    ) {
        self.filter = filter
        self.resultMode = resultMode
        self.maxHits = max(0, maxHits)
    }
}

public struct PhysicsHit: Sendable, Equatable {
    public var entity: EntityID
    public var subShapeID: UInt32
    public var distance: Float
    public var fraction: Float
    public var position: SIMD3<Float>
    public var normal: SIMD3<Float>
    public var bounds: SpatialAABB
    public var isTrigger: Bool

    public init(
        entity: EntityID,
        subShapeID: UInt32 = 0,
        distance: Float = 0,
        fraction: Float = 0,
        position: SIMD3<Float> = .zero,
        normal: SIMD3<Float> = .zero,
        bounds: SpatialAABB,
        isTrigger: Bool
    ) {
        self.entity = entity
        self.subShapeID = subShapeID
        self.distance = distance
        self.fraction = fraction
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

public struct PhysicsVehicleDescriptor: Sendable, Equatable {
    public var entity: EntityID
    public var vehicle: Vehicle

    public init(entity: EntityID, vehicle: Vehicle) {
        self.entity = entity
        self.vehicle = vehicle
    }
}

public struct PhysicsSoftBodyDescriptor: Sendable, Equatable {
    public var entity: EntityID
    public var worldTransform: WorldTransform
    public var softBody: SoftBody
    public var cloth: Cloth

    public init(
        entity: EntityID,
        worldTransform: WorldTransform,
        softBody: SoftBody,
        cloth: Cloth
    ) {
        self.entity = entity
        self.worldTransform = worldTransform
        self.softBody = softBody
        self.cloth = cloth
    }
}

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

public protocol PhysicsBackend: AnyObject, Sendable {
    var identifier: String { get }
    func prepare(context: PhysicsPrepareContext) -> PhysicsPrepareResult
    func step(context: PhysicsStepContext) -> PhysicsStepResult
    func raycast(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter) -> PhysicsRaycastHit?
    func raycastAll(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsRaycastHit]
    func overlapAABB(_ query: PhysicsOverlapAABBQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit]
    func overlapShape(_ query: PhysicsOverlapShapeQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit]
    func sweepAABB(_ query: PhysicsSweepAABBQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit?
    func sweepShape(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit?
    func sweepShapeAll(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsSweepHit]
    func detectTriggerFrame(maxEventCount: Int) -> TriggerFrameResource
    func reset()
}

public extension PhysicsBackend {
    func raycastAll(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsRaycastHit] {
        guard maxHits > 0, let hit = raycast(query, filter: filter) else { return [] }
        return [hit]
    }

    func sweepShapeAll(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsSweepHit] {
        guard maxHits > 0, let hit = sweepShape(query, filter: filter) else { return [] }
        return [hit]
    }
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
        var upsertedVehicles = 0
        var removedVehicles = 0
        var upsertedSoftBodies = 0
        var removedSoftBodies = 0

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
            case .vehicleUpsert:
                upsertedVehicles += 1
            case .vehicleRemove:
                removedVehicles += 1
            case .softBodyUpsert:
                upsertedSoftBodies += 1
            case .softBodyRemove:
                removedSoftBodies += 1
            }
        }

        return PhysicsPrepareResult(
            synchronizedBodies: upsertedBodies,
            synchronizedConstraints: upsertedConstraints,
            removedBodies: removedBodies,
            removedConstraints: removedConstraints,
            synchronizedVehicles: upsertedVehicles,
            removedVehicles: removedVehicles,
            synchronizedSoftBodies: upsertedSoftBodies,
            removedSoftBodies: removedSoftBodies
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

    public func raycastAll(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsRaycastHit] { [] }

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

    public func sweepShapeAll(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter, maxHits: Int) -> [PhysicsSweepHit] { [] }

    public func detectTriggerFrame(maxEventCount: Int) -> TriggerFrameResource {
        TriggerFrameResource()
    }

    public func reset() {}
}

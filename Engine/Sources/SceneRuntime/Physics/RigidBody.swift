import Foundation
import SIMDCompat

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

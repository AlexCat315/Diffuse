import Foundation
import SIMDCompat

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

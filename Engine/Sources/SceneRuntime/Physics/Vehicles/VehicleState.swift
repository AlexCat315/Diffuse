import Foundation
import SIMDCompat

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

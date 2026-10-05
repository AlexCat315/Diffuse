import Foundation
import SIMDCompat

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

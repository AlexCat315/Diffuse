import Foundation
import SIMDCompat

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

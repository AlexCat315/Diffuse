import Foundation
import SIMDCompat

public enum PhysicsJointKind: String, CaseIterable, Sendable, Equatable {
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

public enum PhysicsJointMotorMode: String, CaseIterable, Sendable, Equatable {
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

import Foundation
import SIMDCompat

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

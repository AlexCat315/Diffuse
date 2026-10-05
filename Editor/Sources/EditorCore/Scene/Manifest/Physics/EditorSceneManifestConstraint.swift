import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestConstraint: Codable, Sendable, Equatable {
    public let constraintType: String
    public let entityA: UInt64
    public let entityB: UInt64
    public let pivotA: EditorSceneManifestVector3
    public let pivotB: EditorSceneManifestVector3
    public let axisA: EditorSceneManifestVector3
    public let axisB: EditorSceneManifestVector3
    public let minLimit: Float
    public let maxLimit: Float
    public let isEnabled: Bool
    public let breakForce: Float?
    public let breakTorque: Float?
    public let springFrequency: Float?
    public let springDamping: Float?
    public let motorMode: String?
    public let motorTargetPosition: Float?
    public let motorTargetVelocity: Float?
    public let motorMaxForce: Float?
    public let angularMotorMode: String?
    public let angularMotorTargetPosition: Float?
    public let angularMotorTargetVelocity: Float?
    public let angularMotorMaxForce: Float?
    public let halfConeAngle: Float?
    public let linearMinimum: EditorSceneManifestVector3?
    public let linearMaximum: EditorSceneManifestVector3?
    public let angularMinimum: EditorSceneManifestVector3?
    public let angularMaximum: EditorSceneManifestVector3?

    public init(_ component: Constraint) {
        self.constraintType = component.constraintType.rawValue
        self.entityA = component.entityA.rawValue
        self.entityB = component.entityB.rawValue
        self.pivotA = EditorSceneManifestVector3(component.pivotA)
        self.pivotB = EditorSceneManifestVector3(component.pivotB)
        self.axisA = EditorSceneManifestVector3(component.axisA)
        self.axisB = EditorSceneManifestVector3(component.axisB)
        self.minLimit = component.minLimit
        self.maxLimit = component.maxLimit
        self.isEnabled = component.isEnabled
        self.breakForce = component.breakForce
        self.breakTorque = component.breakTorque
        var spring: PhysicsJointSpring?
        var motor: PhysicsJointMotor?
        var angularMotor: PhysicsJointMotor?
        var coneAngle: Float?
        var linearMin: SIMD3<Float>?
        var linearMax: SIMD3<Float>?
        var angularMin: SIMD3<Float>?
        var angularMax: SIMD3<Float>?
        switch component.configuration {
        case .point, .fixed:
            break
        case let .distance(value):
            spring = value.spring
        case let .hinge(value):
            spring = value.spring; angularMotor = value.motor
        case let .slider(value):
            spring = value.spring; motor = value.motor
        case let .cone(value):
            spring = value.spring; coneAngle = value.halfConeAngle
        case let .sixDOF(value):
            spring = value.spring
            motor = value.linearMotor
            angularMotor = value.angularMotor
            linearMin = value.linearMinimum
            linearMax = value.linearMaximum
            angularMin = value.angularMinimum
            angularMax = value.angularMaximum
        }
        self.springFrequency = spring?.frequency
        self.springDamping = spring?.damping
        self.motorMode = motor?.mode.rawValue
        self.motorTargetPosition = motor?.targetPosition
        self.motorTargetVelocity = motor?.targetVelocity
        self.motorMaxForce = motor?.maxForce
        self.angularMotorMode = angularMotor?.mode.rawValue
        self.angularMotorTargetPosition = angularMotor?.targetPosition
        self.angularMotorTargetVelocity = angularMotor?.targetVelocity
        self.angularMotorMaxForce = angularMotor?.maxForce
        self.halfConeAngle = coneAngle
        self.linearMinimum = linearMin.map(EditorSceneManifestVector3.init)
        self.linearMaximum = linearMax.map(EditorSceneManifestVector3.init)
        self.angularMinimum = angularMin.map(EditorSceneManifestVector3.init)
        self.angularMaximum = angularMax.map(EditorSceneManifestVector3.init)
    }

    func component(idMap: [UInt64: EntityID]) -> Constraint? {
        guard let mappedA = idMap[entityA],
              let mappedB = idMap[entityB]
        else { return nil }
        let spring = PhysicsJointSpring(
            frequency: springFrequency ?? 0,
            damping: springDamping ?? 0
        )
        func motor(angular: Bool = false) -> PhysicsJointMotor {
            PhysicsJointMotor(
                mode: PhysicsJointMotorMode(rawValue: angular ? angularMotorMode ?? "disabled" : motorMode ?? "disabled") ?? .disabled,
                targetPosition: angular ? angularMotorTargetPosition ?? 0 : motorTargetPosition ?? 0,
                targetVelocity: angular ? angularMotorTargetVelocity ?? 0 : motorTargetVelocity ?? 0,
                maxForce: angular ? angularMotorMaxForce ?? .greatestFiniteMagnitude : motorMaxForce ?? .greatestFiniteMagnitude
            )
        }
        let kind = PhysicsJointKind(rawValue: constraintType) ?? .distance
        let configuration: PhysicsJointConfiguration
        switch kind {
        case .pointToPoint:
            configuration = .point
        case .fixed:
            configuration = .fixed(axisA: axisA.simdValue, axisB: axisB.simdValue)
        case .distance:
            configuration = .distance(DistanceJointConfiguration(
                minimumDistance: minLimit, maximumDistance: maxLimit, spring: spring))
        case .hinge:
            configuration = .hinge(HingeJointConfiguration(
                axisA: axisA.simdValue, axisB: axisB.simdValue,
                minimumAngle: minLimit, maximumAngle: maxLimit,
                motor: motor(angular: true), spring: spring))
        case .slider:
            configuration = .slider(SliderJointConfiguration(
                axisA: axisA.simdValue, axisB: axisB.simdValue,
                minimumDistance: minLimit, maximumDistance: maxLimit,
                motor: motor(), spring: spring))
        case .cone:
            configuration = .cone(ConeJointConfiguration(
                twistAxisA: axisA.simdValue, twistAxisB: axisB.simdValue,
                halfConeAngle: halfConeAngle ?? .pi / 4,
                minimumTwistAngle: minLimit, maximumTwistAngle: maxLimit,
                spring: spring))
        case .sixDOF:
            configuration = .sixDOF(SixDOFJointConfiguration(
                axisA: axisA.simdValue, axisB: axisB.simdValue,
                linearMinimum: linearMinimum?.simdValue ?? .zero,
                linearMaximum: linearMaximum?.simdValue ?? .zero,
                angularMinimum: angularMinimum?.simdValue ?? .zero,
                angularMaximum: angularMaximum?.simdValue ?? .zero,
                linearMotor: motor(), angularMotor: motor(angular: true), spring: spring))
        }
        return Constraint(
            configuration: configuration,
            entityA: mappedA,
            entityB: mappedB,
            pivotA: pivotA.simdValue,
            pivotB: pivotB.simdValue,
            isEnabled: isEnabled,
            breakForce: breakForce ?? .greatestFiniteMagnitude,
            breakTorque: breakTorque ?? .greatestFiniteMagnitude
        )
    }
}

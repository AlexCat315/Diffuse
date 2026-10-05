import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestRigidBody: Codable, Sendable, Equatable {
    public let motionType: String
    public let mass: Float
    public let massMode: String
    public let linearVelocity: EditorSceneManifestVector3
    public let angularVelocity: EditorSceneManifestVector3
    public let accumulatedForce: EditorSceneManifestVector3
    public let accumulatedTorque: EditorSceneManifestVector3
    public let accumulatedLinearImpulse: EditorSceneManifestVector3
    public let accumulatedAngularImpulse: EditorSceneManifestVector3
    public let gravityScale: Float
    public let linearDamping: Float
    public let angularDamping: Float
    public let allowSleep: Bool
    public let isSleeping: Bool
    public let continuousCollisionDetection: Bool
    public let centerOfMassOverride: EditorSceneManifestVector3?
    public let inertiaDiagonalOverride: EditorSceneManifestVector3?
    public let axisLocks: UInt8
    public let maxLinearVelocity: Float
    public let maxAngularVelocity: Float
    public let motionQuality: String
    public let kinematicTargetPosition: EditorSceneManifestVector3?
    public let kinematicTargetRotation: EditorSceneManifestVector4?

    private enum CodingKeys: String, CodingKey {
        case motionType
        case mass
        case massMode
        case linearVelocity
        case angularVelocity
        case accumulatedForce
        case accumulatedTorque
        case accumulatedLinearImpulse
        case accumulatedAngularImpulse
        case gravityScale
        case linearDamping
        case angularDamping
        case allowSleep
        case isSleeping
        case continuousCollisionDetection
        case centerOfMassOverride, inertiaDiagonalOverride, axisLocks
        case maxLinearVelocity, maxAngularVelocity, motionQuality
        case kinematicTargetPosition, kinematicTargetRotation
    }

    public init(_ component: RigidBody) {
        self.motionType = component.motionType.rawValue
        self.mass = component.mass
        self.massMode = component.massMode.rawValue
        self.linearVelocity = EditorSceneManifestVector3(component.linearVelocity)
        self.angularVelocity = EditorSceneManifestVector3(component.angularVelocity)
        self.accumulatedForce = EditorSceneManifestVector3(component.accumulatedForce)
        self.accumulatedTorque = EditorSceneManifestVector3(component.accumulatedTorque)
        self.accumulatedLinearImpulse = EditorSceneManifestVector3(component.accumulatedLinearImpulse)
        self.accumulatedAngularImpulse = EditorSceneManifestVector3(component.accumulatedAngularImpulse)
        self.gravityScale = component.gravityScale
        self.linearDamping = component.linearDamping
        self.angularDamping = component.angularDamping
        self.allowSleep = component.allowSleep
        self.isSleeping = component.isSleeping
        self.continuousCollisionDetection = component.continuousCollisionDetection
        self.centerOfMassOverride = component.centerOfMassOverride.map(EditorSceneManifestVector3.init)
        self.inertiaDiagonalOverride = component.inertiaDiagonalOverride.map(EditorSceneManifestVector3.init)
        self.axisLocks = component.axisLocks.rawValue
        self.maxLinearVelocity = component.maxLinearVelocity
        self.maxAngularVelocity = component.maxAngularVelocity
        self.motionQuality = component.motionQuality.rawValue
        self.kinematicTargetPosition = component.kinematicTarget.map { EditorSceneManifestVector3($0.position) }
        self.kinematicTargetRotation = component.kinematicTarget.map { EditorSceneManifestVector4($0.rotation) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        motionType = try c.decode(String.self, forKey: .motionType)
        mass = try c.decode(Float.self, forKey: .mass)
        massMode = try c.decodeIfPresent(String.self, forKey: .massMode) ?? RigidBodyMassMode.mass.rawValue
        linearVelocity = try c.decode(EditorSceneManifestVector3.self, forKey: .linearVelocity)
        angularVelocity = try c.decode(EditorSceneManifestVector3.self, forKey: .angularVelocity)
        accumulatedForce = try c.decode(EditorSceneManifestVector3.self, forKey: .accumulatedForce)
        accumulatedTorque = try c.decode(EditorSceneManifestVector3.self, forKey: .accumulatedTorque)
        accumulatedLinearImpulse = try c.decodeIfPresent(
            EditorSceneManifestVector3.self,
            forKey: .accumulatedLinearImpulse
        ) ?? EditorSceneManifestVector3(.zero)
        accumulatedAngularImpulse = try c.decodeIfPresent(
            EditorSceneManifestVector3.self,
            forKey: .accumulatedAngularImpulse
        ) ?? EditorSceneManifestVector3(.zero)
        gravityScale = try c.decode(Float.self, forKey: .gravityScale)
        linearDamping = try c.decode(Float.self, forKey: .linearDamping)
        angularDamping = try c.decode(Float.self, forKey: .angularDamping)
        allowSleep = try c.decode(Bool.self, forKey: .allowSleep)
        isSleeping = try c.decode(Bool.self, forKey: .isSleeping)
        continuousCollisionDetection = try c.decodeIfPresent(
            Bool.self,
            forKey: .continuousCollisionDetection
        ) ?? false
        centerOfMassOverride = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .centerOfMassOverride)
        inertiaDiagonalOverride = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .inertiaDiagonalOverride)
        axisLocks = try c.decodeIfPresent(UInt8.self, forKey: .axisLocks) ?? 0
        maxLinearVelocity = try c.decodeIfPresent(Float.self, forKey: .maxLinearVelocity) ?? 500
        maxAngularVelocity = try c.decodeIfPresent(Float.self, forKey: .maxAngularVelocity) ?? (0.25 * .pi * 60)
        motionQuality = try c.decodeIfPresent(String.self, forKey: .motionQuality) ?? RigidBodyMotionQuality.discrete.rawValue
        kinematicTargetPosition = try c.decodeIfPresent(EditorSceneManifestVector3.self, forKey: .kinematicTargetPosition)
        kinematicTargetRotation = try c.decodeIfPresent(EditorSceneManifestVector4.self, forKey: .kinematicTargetRotation)
    }

    var component: RigidBody {
        RigidBody(motionType: RigidBodyMotionType(rawValue: motionType) ?? .dynamic,
                  mass: mass,
                  massMode: RigidBodyMassMode(rawValue: massMode) ?? .mass,
                  linearVelocity: linearVelocity.simdValue,
                  angularVelocity: angularVelocity.simdValue,
                  accumulatedForce: accumulatedForce.simdValue,
                  accumulatedTorque: accumulatedTorque.simdValue,
                  accumulatedLinearImpulse: accumulatedLinearImpulse.simdValue,
                  accumulatedAngularImpulse: accumulatedAngularImpulse.simdValue,
                  gravityScale: gravityScale,
                  linearDamping: linearDamping,
                  angularDamping: angularDamping,
                  allowSleep: allowSleep,
                  isSleeping: isSleeping,
                  continuousCollisionDetection: continuousCollisionDetection,
                  centerOfMassOverride: centerOfMassOverride?.simdValue,
                  inertiaDiagonalOverride: inertiaDiagonalOverride?.simdValue,
                  axisLocks: RigidBodyAxisLocks(rawValue: axisLocks),
                  maxLinearVelocity: maxLinearVelocity,
                  maxAngularVelocity: maxAngularVelocity,
                  motionQuality: RigidBodyMotionQuality(rawValue: motionQuality) ?? .discrete,
                  kinematicTarget: kinematicTargetPosition.map {
                      PhysicsKinematicTarget(
                          position: $0.simdValue,
                          rotation: kinematicTargetRotation?.simdValue ?? SIMD4<Float>(0, 0, 0, 1)
                      )
                  })
    }
}

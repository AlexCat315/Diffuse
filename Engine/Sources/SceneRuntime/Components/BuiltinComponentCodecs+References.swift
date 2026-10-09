import Foundation
import SIMDCompat

extension BuiltinComponentCodecs {
    /// Serializes a physics constraint. Endpoints are passed as resolved list indices
    /// (computed by the caller from the entity index map).
    static func serializeConstraint(_ c: Constraint, entityA: Int, entityB: Int) -> [String: Any] {
        var result: [String: Any] = [
            "type": c.constraintType.rawValue,
            "entityA": entityA,
            "entityB": entityB,
            "pivotA": vec3ToJSON(c.pivotA),
            "pivotB": vec3ToJSON(c.pivotB),
            "axisA": vec3ToJSON(c.axisA),
            "axisB": vec3ToJSON(c.axisB),
            "minLimit": c.minLimit,
            "maxLimit": c.maxLimit,
            "isEnabled": c.isEnabled,
            "breakForce": c.breakForce,
            "breakTorque": c.breakTorque,
        ]
        func storeSpring(_ spring: PhysicsJointSpring) {
            result["springFrequency"] = spring.frequency
            result["springDamping"] = spring.damping
        }
        func storeMotor(_ motor: PhysicsJointMotor, prefix: String = "motor") {
            result["\(prefix)Mode"] = motor.mode.rawValue
            result["\(prefix)TargetPosition"] = motor.targetPosition
            result["\(prefix)TargetVelocity"] = motor.targetVelocity
            result["\(prefix)MaxForce"] = motor.maxForce
        }
        switch c.configuration {
        case .point, .fixed:
            break
        case let .distance(value):
            storeSpring(value.spring)
        case let .hinge(value):
            storeSpring(value.spring); storeMotor(value.motor)
        case let .slider(value):
            storeSpring(value.spring); storeMotor(value.motor)
        case let .cone(value):
            result["halfConeAngle"] = value.halfConeAngle
            storeSpring(value.spring)
        case let .sixDOF(value):
            result["linearMinimum"] = vec3ToJSON(value.linearMinimum)
            result["linearMaximum"] = vec3ToJSON(value.linearMaximum)
            result["angularMinimum"] = vec3ToJSON(value.angularMinimum)
            result["angularMaximum"] = vec3ToJSON(value.angularMaximum)
            storeSpring(value.spring)
            storeMotor(value.linearMotor)
            storeMotor(value.angularMotor, prefix: "angularMotor")
        }
        return result
    }

    static func deserializeConstraint(_ d: [String: Any], entityA: EntityID, entityB: EntityID) -> Constraint {
        let kind = PhysicsJointKind(rawValue: jsonToString(d["type"]) ?? "pointToPoint") ?? .pointToPoint
        let axisA = jsonToFloatArray(d["axisA"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0)
        let axisB = jsonToFloatArray(d["axisB"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0)
        let minimum = jsonToFloat(d["minLimit"]) ?? 0
        let maximum = jsonToFloat(d["maxLimit"]) ?? 0
        let spring = PhysicsJointSpring(
            frequency: jsonToFloat(d["springFrequency"]) ?? 0,
            damping: jsonToFloat(d["springDamping"]) ?? 0
        )
        func motor(prefix: String = "motor") -> PhysicsJointMotor {
            PhysicsJointMotor(
                mode: PhysicsJointMotorMode(rawValue: jsonToString(d["\(prefix)Mode"]) ?? "disabled") ?? .disabled,
                targetPosition: jsonToFloat(d["\(prefix)TargetPosition"]) ?? 0,
                targetVelocity: jsonToFloat(d["\(prefix)TargetVelocity"]) ?? 0,
                maxForce: jsonToFloat(d["\(prefix)MaxForce"]) ?? .greatestFiniteMagnitude
            )
        }
        let configuration: PhysicsJointConfiguration
        switch kind {
        case .pointToPoint:
            configuration = .point
        case .fixed:
            configuration = .fixed(axisA: axisA, axisB: axisB)
        case .distance:
            configuration = .distance(DistanceJointConfiguration(
                minimumDistance: minimum, maximumDistance: maximum, spring: spring))
        case .hinge:
            configuration = .hinge(HingeJointConfiguration(
                axisA: axisA, axisB: axisB, minimumAngle: minimum, maximumAngle: maximum,
                motor: motor(), spring: spring))
        case .slider:
            configuration = .slider(SliderJointConfiguration(
                axisA: axisA, axisB: axisB, minimumDistance: minimum, maximumDistance: maximum,
                motor: motor(), spring: spring))
        case .cone:
            configuration = .cone(ConeJointConfiguration(
                twistAxisA: axisA, twistAxisB: axisB,
                halfConeAngle: jsonToFloat(d["halfConeAngle"]) ?? .pi / 4,
                minimumTwistAngle: minimum, maximumTwistAngle: maximum, spring: spring))
        case .sixDOF:
            configuration = .sixDOF(SixDOFJointConfiguration(
                axisA: axisA,
                axisB: axisB,
                linearMinimum: jsonToFloatArray(d["linearMinimum"]).flatMap(jsonToVec3) ?? .zero,
                linearMaximum: jsonToFloatArray(d["linearMaximum"]).flatMap(jsonToVec3) ?? .zero,
                angularMinimum: jsonToFloatArray(d["angularMinimum"]).flatMap(jsonToVec3) ?? .zero,
                angularMaximum: jsonToFloatArray(d["angularMaximum"]).flatMap(jsonToVec3) ?? .zero,
                linearMotor: motor(),
                angularMotor: motor(prefix: "angularMotor"),
                spring: spring
            ))
        }
        return Constraint(
            configuration: configuration,
            entityA: entityA,
            entityB: entityB,
            pivotA: jsonToFloatArray(d["pivotA"]).flatMap(jsonToVec3) ?? .zero,
            pivotB: jsonToFloatArray(d["pivotB"]).flatMap(jsonToVec3) ?? .zero,
            isEnabled: jsonToBool(d["isEnabled"]) ?? true,
            breakForce: jsonToFloat(d["breakForce"]) ?? .greatestFiniteMagnitude,
            breakTorque: jsonToFloat(d["breakTorque"]) ?? .greatestFiniteMagnitude
        )
    }

    static func serializeRagdoll(
        _ ragdoll: Ragdoll,
        entityIndexMap: [EntityID: Int]
    ) -> [String: Any] {
        let bones: [[String: Any]] = ragdoll.bones.compactMap { bone in
            guard let body = entityIndexMap[bone.bodyEntity] else { return nil }
            var result: [String: Any] = [
                "boneName": bone.boneName,
                "paletteIndex": bone.paletteIndex,
                "bodyEntity": body,
                "bodyFromPalette": matrixToJSON(bone.bodyFromPalette),
                "simulatedMotionType": bone.simulatedMotionType.rawValue,
                "isSimulationEnabled": bone.isSimulationEnabled,
                "blendWeight": bone.blendWeight,
            ]
            if let jointEntity = bone.jointEntity.flatMap({ entityIndexMap[$0] }) {
                result["jointEntity"] = jointEntity
            }
            return result
        }
        return [
            "mode": ragdoll.mode.rawValue,
            "blendWeight": ragdoll.blendWeight,
            "isEnabled": ragdoll.isEnabled,
            "bones": bones,
        ]
    }

    static func deserializeRagdoll(
        _ dictionary: [String: Any],
        entityMap: [Int: EntityID]
    ) -> Ragdoll {
        let bones = (jsonToArray(dictionary["bones"]) ?? []).compactMap { raw -> RagdollBoneMapping? in
            guard let bone = jsonToDict(raw),
                  let bodyIndex = jsonToInt(bone["bodyEntity"]),
                  let bodyEntity = entityMap[bodyIndex]
            else { return nil }
            let jointEntity = jsonToInt(bone["jointEntity"]).flatMap { entityMap[$0] }
            return RagdollBoneMapping(
                boneName: jsonToString(bone["boneName"]) ?? "",
                paletteIndex: jsonToInt(bone["paletteIndex"]) ?? 0,
                bodyEntity: bodyEntity,
                jointEntity: jointEntity,
                bodyFromPalette: jsonToFloatArray(bone["bodyFromPalette"]).flatMap(jsonToMatrix)
                    ?? matrix_identity_float4x4,
                simulatedMotionType: RigidBodyMotionType(
                    rawValue: jsonToString(bone["simulatedMotionType"]) ?? "dynamic"
                ) ?? .dynamic,
                isSimulationEnabled: jsonToBool(bone["isSimulationEnabled"]) ?? true,
                blendWeight: jsonToFloat(bone["blendWeight"]) ?? 1
            )
        }
        return Ragdoll(
            mode: RagdollMode(rawValue: jsonToString(dictionary["mode"]) ?? "animated") ?? .animated,
            blendWeight: jsonToFloat(dictionary["blendWeight"]) ?? 1,
            isEnabled: jsonToBool(dictionary["isEnabled"]) ?? true,
            bones: bones
        )
    }
}

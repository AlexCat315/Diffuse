import Foundation
import SIMDCompat

extension BuiltinComponentCodecs {
    // MARK: - Component serializers

    static func serializeRigidBody(_ c: RigidBody) -> [String: Any] {
        var d: [String: Any] = [
            "motionType": c.motionType.rawValue,
            "mass": c.mass,
            "massMode": c.massMode.rawValue,
            "linearVelocity": vec3ToJSON(c.linearVelocity),
            "angularVelocity": vec3ToJSON(c.angularVelocity),
            "accumulatedForce": vec3ToJSON(c.accumulatedForce),
            "accumulatedTorque": vec3ToJSON(c.accumulatedTorque),
            "accumulatedLinearImpulse": vec3ToJSON(c.accumulatedLinearImpulse),
            "accumulatedAngularImpulse": vec3ToJSON(c.accumulatedAngularImpulse),
            "linearDamping": c.linearDamping,
            "angularDamping": c.angularDamping,
            "gravityScale": c.gravityScale,
            "allowSleep": c.allowSleep,
            "isSleeping": c.isSleeping,
            "continuousCollisionDetection": c.continuousCollisionDetection,
            "axisLocks": c.axisLocks.rawValue,
            "maxLinearVelocity": c.maxLinearVelocity,
            "maxAngularVelocity": c.maxAngularVelocity,
            "motionQuality": c.motionQuality.rawValue,
        ]
        if let centerOfMassOverride = c.centerOfMassOverride {
            d["centerOfMassOverride"] = vec3ToJSON(centerOfMassOverride)
        }
        if let inertiaDiagonalOverride = c.inertiaDiagonalOverride {
            d["inertiaDiagonalOverride"] = vec3ToJSON(inertiaDiagonalOverride)
        }
        if let target = c.kinematicTarget {
            d["kinematicTarget"] = [
                "position": vec3ToJSON(target.position),
                "rotation": vec4ToJSON(target.rotation),
            ]
        }
        return d
    }

    static func deserializeRigidBody(_ d: [String: Any]) -> RigidBody {
        RigidBody(
            motionType: RigidBodyMotionType(rawValue: jsonToString(d["motionType"]) ?? "dynamic") ?? .dynamic,
            mass: jsonToFloat(d["mass"]) ?? 1,
            massMode: RigidBodyMassMode(rawValue: jsonToString(d["massMode"]) ?? "mass") ?? .mass,
            linearVelocity: jsonToFloatArray(d["linearVelocity"]).flatMap(jsonToVec3) ?? .zero,
            angularVelocity: jsonToFloatArray(d["angularVelocity"]).flatMap(jsonToVec3) ?? .zero,
            accumulatedForce: jsonToFloatArray(d["accumulatedForce"]).flatMap(jsonToVec3) ?? .zero,
            accumulatedTorque: jsonToFloatArray(d["accumulatedTorque"]).flatMap(jsonToVec3) ?? .zero,
            accumulatedLinearImpulse: jsonToFloatArray(d["accumulatedLinearImpulse"])
                .flatMap(jsonToVec3) ?? .zero,
            accumulatedAngularImpulse: jsonToFloatArray(d["accumulatedAngularImpulse"])
                .flatMap(jsonToVec3) ?? .zero,
            gravityScale: jsonToFloat(d["gravityScale"]) ?? 1,
            linearDamping: jsonToFloat(d["linearDamping"]) ?? 0.04,
            angularDamping: jsonToFloat(d["angularDamping"]) ?? 0.04,
            allowSleep: jsonToBool(d["allowSleep"]) ?? true,
            isSleeping: jsonToBool(d["isSleeping"]) ?? false,
            continuousCollisionDetection: jsonToBool(d["continuousCollisionDetection"]) ?? false,
            centerOfMassOverride: jsonToFloatArray(d["centerOfMassOverride"]).flatMap(jsonToVec3),
            inertiaDiagonalOverride: jsonToFloatArray(d["inertiaDiagonalOverride"]).flatMap(jsonToVec3),
            axisLocks: RigidBodyAxisLocks(rawValue: UInt8(clamping: jsonToInt(d["axisLocks"]) ?? 0)),
            maxLinearVelocity: jsonToFloat(d["maxLinearVelocity"]) ?? 500,
            maxAngularVelocity: jsonToFloat(d["maxAngularVelocity"]) ?? (0.25 * .pi * 60),
            motionQuality: RigidBodyMotionQuality(rawValue: jsonToString(d["motionQuality"]) ?? "discrete") ?? .discrete,
            kinematicTarget: jsonToDict(d["kinematicTarget"]).flatMap { target in
                guard let position = jsonToFloatArray(target["position"]).flatMap(jsonToVec3) else { return nil }
                let rotation = jsonToFloatArray(target["rotation"]).flatMap(jsonToVec4)
                    ?? SIMD4<Float>(0, 0, 0, 1)
                return PhysicsKinematicTarget(position: position, rotation: rotation)
            }
        )
    }

    static func serializeCollider(_ c: Collider) -> [String: Any] {
        var d: [String: Any] = [
            "isTrigger": c.isTrigger,
            "layerID": c.layerID,
            "layerMask": c.layerMask,
            "friction": c.material.friction,
            "restitution": c.material.restitution,
            "density": c.material.density,
        ]
        d["shapes"] = c.shapes.map { instance in
            var encoded = serializeColliderShape(instance.shape)
            encoded["localPosition"] = vec3ToJSON(instance.localPosition)
            encoded["localRotation"] = vec4ToJSON(instance.localRotation)
            encoded["localScale"] = vec3ToJSON(instance.localScale)
            return encoded
        }
        switch c.shape {
        case let .box(he, center):
            d["shape"] = "box"
            d["halfExtents"] = vec3ToJSON(he)
            d["center"] = vec3ToJSON(center)
        case let .sphere(radius, center):
            d["shape"] = "sphere"
            d["radius"] = radius
            d["center"] = vec3ToJSON(center)
        case let .capsule(radius, halfHeight, center):
            d["shape"] = "capsule"
            d["radius"] = radius
            d["halfHeight"] = halfHeight
            d["center"] = vec3ToJSON(center)
        case let .cylinder(radius, halfHeight, center):
            d["shape"] = "cylinder"
            d["radius"] = radius
            d["halfHeight"] = halfHeight
            d["center"] = vec3ToJSON(center)
        case let .heightField(resourceID, center):
            d["shape"] = "heightField"
            d["resourceID"] = resourceID ?? ""
            d["center"] = vec3ToJSON(center)
        case let .mesh(resourceID, center):
            d["shape"] = "mesh"
            d["resourceID"] = resourceID ?? ""
            d["center"] = vec3ToJSON(center)
        case let .convex(resourceID, center):
            d["shape"] = "convex"
            d["resourceID"] = resourceID ?? ""
            d["center"] = vec3ToJSON(center)
        }
        return d
    }

    static func serializeColliderShape(_ shape: ColliderShape) -> [String: Any] {
        var d: [String: Any] = ["center": vec3ToJSON(shape.center)]
        switch shape {
        case let .box(halfExtents, _):
            d["shape"] = "box"; d["halfExtents"] = vec3ToJSON(halfExtents)
        case let .sphere(radius, _):
            d["shape"] = "sphere"; d["radius"] = radius
        case let .capsule(radius, halfHeight, _):
            d["shape"] = "capsule"; d["radius"] = radius; d["halfHeight"] = halfHeight
        case let .cylinder(radius, halfHeight, _):
            d["shape"] = "cylinder"; d["radius"] = radius; d["halfHeight"] = halfHeight
        case let .heightField(resourceID, _):
            d["shape"] = "heightField"; d["resourceID"] = resourceID ?? ""
        case let .mesh(resourceID, _):
            d["shape"] = "mesh"; d["resourceID"] = resourceID ?? ""
        case let .convex(resourceID, _):
            d["shape"] = "convex"; d["resourceID"] = resourceID ?? ""
        }
        return d
    }

    static func deserializeCollider(_ d: [String: Any]) -> Collider {
        let center = jsonToFloatArray(d["center"]).flatMap(jsonToVec3) ?? .zero
        let shape: ColliderShape
        switch jsonToString(d["shape"]) ?? "box" {
        case "sphere":
            shape = .sphere(radius: jsonToFloat(d["radius"]) ?? 0.5, center: center)
        case "capsule":
            shape = .capsule(radius: jsonToFloat(d["radius"]) ?? 0.5,
                           halfHeight: jsonToFloat(d["halfHeight"]) ?? 1, center: center)
        case "cylinder":
            shape = .cylinder(radius: jsonToFloat(d["radius"]) ?? 0.5,
                              halfHeight: jsonToFloat(d["halfHeight"]) ?? 0.5,
                              center: center)
        case "heightField":
            shape = .heightField(resourceID: jsonToString(d["resourceID"]), center: center)
        case "mesh":
            shape = .mesh(resourceID: jsonToString(d["resourceID"]), center: center)
        case "convex":
            shape = .convex(resourceID: jsonToString(d["resourceID"]), center: center)
        default:
            let he = jsonToFloatArray(d["halfExtents"]).flatMap(jsonToVec3) ?? SIMD3<Float>(repeating: 0.5)
            shape = .box(halfExtents: he, center: center)
        }
        let instances = jsonToArray(d["shapes"])?.compactMap { value -> ColliderShapeInstance? in
            guard let encoded = jsonToDict(value) else { return nil }
            let localPosition = jsonToFloatArray(encoded["localPosition"]).flatMap(jsonToVec3) ?? .zero
            let localRotation = jsonToFloatArray(encoded["localRotation"]).flatMap(jsonToVec4)
                ?? SIMD4<Float>(0, 0, 0, 1)
            let localScale = jsonToFloatArray(encoded["localScale"]).flatMap(jsonToVec3)
                ?? SIMD3<Float>(repeating: 1)
            return ColliderShapeInstance(
                shape: deserializeColliderShape(encoded),
                localPosition: localPosition,
                localRotation: localRotation,
                localScale: localScale
            )
        }
        return Collider(
            shapes: instances ?? [ColliderShapeInstance(shape: shape)],
            isTrigger: jsonToBool(d["isTrigger"]) ?? false,
            layerID: UInt16(clamping: jsonToInt(d["layerID"]) ?? 0),
            layerMask: UInt16(clamping: jsonToInt(d["layerMask"]) ?? Int(UInt16.max)),
            material: PhysicsMaterial(
                friction: jsonToFloat(d["friction"]) ?? 0.6,
                restitution: jsonToFloat(d["restitution"]) ?? 0,
                density: jsonToFloat(d["density"]) ?? 1
            )
        )
    }

    static func deserializeColliderShape(_ d: [String: Any]) -> ColliderShape {
        let center = jsonToFloatArray(d["center"]).flatMap(jsonToVec3) ?? .zero
        switch jsonToString(d["shape"]) ?? "box" {
        case "sphere": return .sphere(radius: jsonToFloat(d["radius"]) ?? 0.5, center: center)
        case "capsule": return .capsule(radius: jsonToFloat(d["radius"]) ?? 0.5,
                                         halfHeight: jsonToFloat(d["halfHeight"]) ?? 0.5,
                                         center: center)
        case "cylinder": return .cylinder(radius: jsonToFloat(d["radius"]) ?? 0.5,
                                            halfHeight: jsonToFloat(d["halfHeight"]) ?? 0.5,
                                            center: center)
        case "heightField": return .heightField(resourceID: jsonToString(d["resourceID"]), center: center)
        case "mesh": return .mesh(resourceID: jsonToString(d["resourceID"]), center: center)
        case "convex": return .convex(resourceID: jsonToString(d["resourceID"]), center: center)
        default:
            return .box(
                halfExtents: jsonToFloatArray(d["halfExtents"]).flatMap(jsonToVec3)
                    ?? SIMD3<Float>(repeating: 0.5),
                center: center
            )
        }
    }

    static func serializeCharacterController(_ c: CharacterController) -> [String: Any] {
        [
            "radius": c.radius,
            "standingHalfHeight": c.standingHalfHeight,
            "crouchingHalfHeight": c.crouchingHalfHeight,
            "center": vec3ToJSON(c.center),
            "maxSlopeDegrees": c.maxSlopeDegrees,
            "stepHeight": c.stepHeight,
            "skinWidth": c.skinWidth,
            "mass": c.mass,
            "maxStrength": c.maxStrength,
            "gravityScale": c.gravityScale,
            "layerID": c.layerID,
            "layerMask": c.layerMask,
        ]
    }

    static func deserializeCharacterController(_ d: [String: Any]) -> CharacterController {
        CharacterController(
            radius: jsonToFloat(d["radius"]) ?? 0.4,
            standingHalfHeight: jsonToFloat(d["standingHalfHeight"]) ?? 0.6,
            crouchingHalfHeight: jsonToFloat(d["crouchingHalfHeight"]) ?? 0.25,
            center: jsonToFloatArray(d["center"]).flatMap(jsonToVec3) ?? .zero,
            maxSlopeDegrees: jsonToFloat(d["maxSlopeDegrees"]) ?? 50,
            stepHeight: jsonToFloat(d["stepHeight"]) ?? 0.4,
            skinWidth: jsonToFloat(d["skinWidth"]) ?? 0.02,
            mass: jsonToFloat(d["mass"]) ?? 70,
            maxStrength: jsonToFloat(d["maxStrength"]) ?? 100,
            gravityScale: jsonToFloat(d["gravityScale"]) ?? 1,
            layerID: UInt16(clamping: jsonToInt(d["layerID"]) ?? 0),
            layerMask: UInt16(clamping: jsonToInt(d["layerMask"]) ?? Int(UInt16.max))
        )
    }

    static func serializeVehicle(_ vehicle: Vehicle) -> [String: Any] {
        let controller: [String: Any]
        switch vehicle.controller {
        case .wheeled:
            controller = ["kind": VehicleControllerKind.wheeled.rawValue]
        case let .tracked(configuration):
            func serializeTrack(_ track: VehicleTrackConfiguration) -> [String: Any] {
                [
                    "drivenWheel": track.drivenWheel,
                    "wheels": track.wheels,
                    "inertia": track.inertia,
                    "angularDamping": track.angularDamping,
                    "maxBrakeTorque": track.maxBrakeTorque,
                    "differentialRatio": track.differentialRatio,
                ]
            }
            controller = [
                "kind": VehicleControllerKind.tracked.rawValue,
                "leftTrack": serializeTrack(configuration.leftTrack),
                "rightTrack": serializeTrack(configuration.rightTrack),
                "longitudinalFriction": configuration.longitudinalFriction,
                "lateralFriction": configuration.lateralFriction,
            ]
        case let .motorcycle(configuration):
            controller = [
                "kind": VehicleControllerKind.motorcycle.rawValue,
                "maxLeanAngle": configuration.maxLeanAngle,
                "leanSpringConstant": configuration.leanSpringConstant,
                "leanSpringDamping": configuration.leanSpringDamping,
                "leanSpringIntegrationCoefficient": configuration.leanSpringIntegrationCoefficient,
                "leanSpringIntegrationCoefficientDecay": configuration.leanSpringIntegrationCoefficientDecay,
                "leanSmoothingFactor": configuration.leanSmoothingFactor,
                "isLeanControllerEnabled": configuration.isLeanControllerEnabled,
                "isLeanSteeringLimitEnabled": configuration.isLeanSteeringLimitEnabled,
            ]
        }
        return [
            "isEnabled": vehicle.isEnabled,
            "controller": controller,
            "up": vec3ToJSON(vehicle.up),
            "forward": vec3ToJSON(vehicle.forward),
            "maxPitchRollAngle": vehicle.maxPitchRollAngle,
            "engine": [
                "maxTorque": vehicle.engine.maxTorque,
                "minRPM": vehicle.engine.minRPM,
                "maxRPM": vehicle.engine.maxRPM,
                "inertia": vehicle.engine.inertia,
                "angularDamping": vehicle.engine.angularDamping,
            ],
            "transmission": [
                "mode": vehicle.transmission.mode.rawValue,
                "gearRatios": vehicle.transmission.gearRatios,
                "reverseGearRatios": vehicle.transmission.reverseGearRatios,
                "switchTime": vehicle.transmission.switchTime,
                "clutchReleaseTime": vehicle.transmission.clutchReleaseTime,
                "switchLatency": vehicle.transmission.switchLatency,
                "shiftUpRPM": vehicle.transmission.shiftUpRPM,
                "shiftDownRPM": vehicle.transmission.shiftDownRPM,
                "clutchStrength": vehicle.transmission.clutchStrength,
            ],
            "wheels": vehicle.wheels.map { wheel in
                [
                    "position": vec3ToJSON(wheel.position),
                    "suspensionDirection": vec3ToJSON(wheel.suspensionDirection),
                    "steeringAxis": vec3ToJSON(wheel.steeringAxis),
                    "wheelUp": vec3ToJSON(wheel.wheelUp),
                    "wheelForward": vec3ToJSON(wheel.wheelForward),
                    "suspensionMinLength": wheel.suspensionMinLength,
                    "suspensionMaxLength": wheel.suspensionMaxLength,
                    "suspensionPreloadLength": wheel.suspensionPreloadLength,
                    "suspensionFrequency": wheel.suspensionFrequency,
                    "suspensionDamping": wheel.suspensionDamping,
                    "radius": wheel.radius,
                    "width": wheel.width,
                    "inertia": wheel.inertia,
                    "angularDamping": wheel.angularDamping,
                    "maxSteerAngle": wheel.maxSteerAngle,
                    "maxBrakeTorque": wheel.maxBrakeTorque,
                    "maxHandBrakeTorque": wheel.maxHandBrakeTorque,
                ] as [String: Any]
            },
            "differentials": vehicle.differentials.map { differential in
                [
                    "leftWheel": differential.leftWheel,
                    "rightWheel": differential.rightWheel,
                    "differentialRatio": differential.differentialRatio,
                    "leftRightSplit": differential.leftRightSplit,
                    "limitedSlipRatio": differential.limitedSlipRatio,
                    "engineTorqueRatio": differential.engineTorqueRatio,
                ] as [String: Any]
            },
            "antiRollBars": vehicle.antiRollBars.map { bar in
                [
                    "leftWheel": bar.leftWheel,
                    "rightWheel": bar.rightWheel,
                    "stiffness": bar.stiffness,
                ] as [String: Any]
            },
        ]
    }

    static func deserializeVehicle(_ d: [String: Any]) -> Vehicle {
        let defaultVehicle = Vehicle()
        let controllerDictionary = jsonToDict(d["controller"])
        let engineDictionary = jsonToDict(d["engine"])
        let transmissionDictionary = jsonToDict(d["transmission"])
        let wheels = jsonToArray(d["wheels"])?.compactMap { raw -> VehicleWheelConfiguration? in
            guard let wheel = jsonToDict(raw) else { return nil }
            return VehicleWheelConfiguration(
                position: jsonToFloatArray(wheel["position"]).flatMap(jsonToVec3) ?? .zero,
                suspensionDirection: jsonToFloatArray(wheel["suspensionDirection"]).flatMap(jsonToVec3)
                    ?? SIMD3<Float>(0, -1, 0),
                steeringAxis: jsonToFloatArray(wheel["steeringAxis"]).flatMap(jsonToVec3)
                    ?? SIMD3<Float>(0, 1, 0),
                wheelUp: jsonToFloatArray(wheel["wheelUp"]).flatMap(jsonToVec3)
                    ?? SIMD3<Float>(0, 1, 0),
                wheelForward: jsonToFloatArray(wheel["wheelForward"]).flatMap(jsonToVec3)
                    ?? SIMD3<Float>(0, 0, 1),
                suspensionMinLength: jsonToFloat(wheel["suspensionMinLength"]) ?? 0.2,
                suspensionMaxLength: jsonToFloat(wheel["suspensionMaxLength"]) ?? 0.5,
                suspensionPreloadLength: jsonToFloat(wheel["suspensionPreloadLength"]) ?? 0,
                suspensionFrequency: jsonToFloat(wheel["suspensionFrequency"]) ?? 1.5,
                suspensionDamping: jsonToFloat(wheel["suspensionDamping"]) ?? 0.5,
                radius: jsonToFloat(wheel["radius"]) ?? 0.35,
                width: jsonToFloat(wheel["width"]) ?? 0.2,
                inertia: jsonToFloat(wheel["inertia"]) ?? 0.9,
                angularDamping: jsonToFloat(wheel["angularDamping"]) ?? 0.2,
                maxSteerAngle: jsonToFloat(wheel["maxSteerAngle"]) ?? 0,
                maxBrakeTorque: jsonToFloat(wheel["maxBrakeTorque"]) ?? 1_500,
                maxHandBrakeTorque: jsonToFloat(wheel["maxHandBrakeTorque"]) ?? 0
            )
        } ?? defaultVehicle.wheels
        let differentials = jsonToArray(d["differentials"])?.compactMap { raw -> VehicleDifferentialConfiguration? in
            guard let differential = jsonToDict(raw),
                  let left = jsonToInt(differential["leftWheel"]),
                  let right = jsonToInt(differential["rightWheel"])
            else { return nil }
            return VehicleDifferentialConfiguration(
                leftWheel: left,
                rightWheel: right,
                differentialRatio: jsonToFloat(differential["differentialRatio"]) ?? 3.42,
                leftRightSplit: jsonToFloat(differential["leftRightSplit"]) ?? 0.5,
                limitedSlipRatio: jsonToFloat(differential["limitedSlipRatio"]) ?? 1.4,
                engineTorqueRatio: jsonToFloat(differential["engineTorqueRatio"]) ?? 1
            )
        } ?? defaultVehicle.differentials
        let antiRollBars = jsonToArray(d["antiRollBars"])?.compactMap { raw -> VehicleAntiRollBarConfiguration? in
            guard let bar = jsonToDict(raw),
                  let left = jsonToInt(bar["leftWheel"]),
                  let right = jsonToInt(bar["rightWheel"])
            else { return nil }
            return VehicleAntiRollBarConfiguration(
                leftWheel: left,
                rightWheel: right,
                stiffness: jsonToFloat(bar["stiffness"]) ?? 1_000
            )
        } ?? defaultVehicle.antiRollBars
        let engine = VehicleEngineConfiguration(
            maxTorque: jsonToFloat(engineDictionary?["maxTorque"]) ?? 500,
            minRPM: jsonToFloat(engineDictionary?["minRPM"]) ?? 1_000,
            maxRPM: jsonToFloat(engineDictionary?["maxRPM"]) ?? 6_000,
            inertia: jsonToFloat(engineDictionary?["inertia"]) ?? 0.5,
            angularDamping: jsonToFloat(engineDictionary?["angularDamping"]) ?? 0.2
        )
        let transmission = VehicleTransmissionConfiguration(
            mode: VehicleTransmissionMode(
                rawValue: UInt8(clamping: jsonToInt(transmissionDictionary?["mode"]) ?? 0)
            ) ?? .automatic,
            gearRatios: jsonToFloatArray(transmissionDictionary?["gearRatios"]) ?? [2.66, 1.78, 1.3, 1, 0.74],
            reverseGearRatios: jsonToFloatArray(transmissionDictionary?["reverseGearRatios"]) ?? [-2.9],
            switchTime: jsonToFloat(transmissionDictionary?["switchTime"]) ?? 0.5,
            clutchReleaseTime: jsonToFloat(transmissionDictionary?["clutchReleaseTime"]) ?? 0.3,
            switchLatency: jsonToFloat(transmissionDictionary?["switchLatency"]) ?? 0.5,
            shiftUpRPM: jsonToFloat(transmissionDictionary?["shiftUpRPM"]) ?? 4_000,
            shiftDownRPM: jsonToFloat(transmissionDictionary?["shiftDownRPM"]) ?? 2_000,
            clutchStrength: jsonToFloat(transmissionDictionary?["clutchStrength"]) ?? 10
        )
        let controller: VehicleControllerConfiguration
        switch VehicleControllerKind(
            rawValue: UInt8(clamping: jsonToInt(controllerDictionary?["kind"]) ?? 0)
        ) ?? .wheeled {
        case .wheeled:
            controller = .wheeled
        case .tracked:
            func deserializeTrack(
                _ dictionary: [String: Any]?,
                fallback: VehicleTrackConfiguration
            ) -> VehicleTrackConfiguration {
                guard let dictionary else { return fallback }
                return VehicleTrackConfiguration(
                    drivenWheel: jsonToInt(dictionary["drivenWheel"]) ?? fallback.drivenWheel,
                    wheels: (jsonToArray(dictionary["wheels"]) ?? []).compactMap(jsonToInt),
                    inertia: jsonToFloat(dictionary["inertia"]) ?? fallback.inertia,
                    angularDamping: jsonToFloat(dictionary["angularDamping"]) ?? fallback.angularDamping,
                    maxBrakeTorque: jsonToFloat(dictionary["maxBrakeTorque"]) ?? fallback.maxBrakeTorque,
                    differentialRatio: jsonToFloat(dictionary["differentialRatio"])
                        ?? fallback.differentialRatio
                )
            }
            let defaults = Vehicle.tracked()
            let fallback: TrackedVehicleConfiguration
            if case let .tracked(value) = defaults.controller {
                fallback = value
            } else {
                preconditionFailure("Vehicle.tracked() must use a tracked controller")
            }
            controller = .tracked(TrackedVehicleConfiguration(
                leftTrack: deserializeTrack(
                    jsonToDict(controllerDictionary?["leftTrack"]), fallback: fallback.leftTrack
                ),
                rightTrack: deserializeTrack(
                    jsonToDict(controllerDictionary?["rightTrack"]), fallback: fallback.rightTrack
                ),
                longitudinalFriction: jsonToFloat(controllerDictionary?["longitudinalFriction"])
                    ?? fallback.longitudinalFriction,
                lateralFriction: jsonToFloat(controllerDictionary?["lateralFriction"])
                    ?? fallback.lateralFriction
            ))
        case .motorcycle:
            controller = .motorcycle(MotorcycleVehicleConfiguration(
                maxLeanAngle: jsonToFloat(controllerDictionary?["maxLeanAngle"]) ?? .pi / 4,
                leanSpringConstant: jsonToFloat(controllerDictionary?["leanSpringConstant"]) ?? 5_000,
                leanSpringDamping: jsonToFloat(controllerDictionary?["leanSpringDamping"]) ?? 1_000,
                leanSpringIntegrationCoefficient:
                    jsonToFloat(controllerDictionary?["leanSpringIntegrationCoefficient"]) ?? 0,
                leanSpringIntegrationCoefficientDecay:
                    jsonToFloat(controllerDictionary?["leanSpringIntegrationCoefficientDecay"]) ?? 4,
                leanSmoothingFactor: jsonToFloat(controllerDictionary?["leanSmoothingFactor"]) ?? 0.8,
                isLeanControllerEnabled:
                    jsonToBool(controllerDictionary?["isLeanControllerEnabled"]) ?? true,
                isLeanSteeringLimitEnabled:
                    jsonToBool(controllerDictionary?["isLeanSteeringLimitEnabled"]) ?? true
            ))
        }
        return Vehicle(
            controller: controller,
            wheels: wheels,
            differentials: differentials,
            antiRollBars: antiRollBars,
            engine: engine,
            transmission: transmission,
            up: jsonToFloatArray(d["up"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 1, 0),
            forward: jsonToFloatArray(d["forward"]).flatMap(jsonToVec3) ?? SIMD3<Float>(0, 0, 1),
            maxPitchRollAngle: jsonToFloat(d["maxPitchRollAngle"]) ?? .pi,
            isEnabled: jsonToBool(d["isEnabled"]) ?? true
        )
    }

    static func serializeSoftBody(_ body: SoftBody) -> [String: Any] {
        [
            "vertexMass": body.vertexMass,
            "pressure": body.pressure,
            "linearDamping": body.linearDamping,
            "friction": body.friction,
            "restitution": body.restitution,
            "gravityScale": body.gravityScale,
            "vertexRadius": body.vertexRadius,
            "solverIterations": body.solverIterations,
            "maxLinearVelocity": body.maxLinearVelocity,
            "layerID": body.layerID,
            "layerMask": body.layerMask,
            "allowSleep": body.allowSleep,
            "facesDoubleSided": body.facesDoubleSided,
            "selfCollision": body.selfCollision,
            "isEnabled": body.isEnabled,
        ]
    }

    static func deserializeSoftBody(_ d: [String: Any]) -> SoftBody {
        SoftBody(
            vertexMass: jsonToFloat(d["vertexMass"]) ?? 1,
            pressure: jsonToFloat(d["pressure"]) ?? 0,
            linearDamping: jsonToFloat(d["linearDamping"]) ?? 0.1,
            friction: jsonToFloat(d["friction"]) ?? 0.2,
            restitution: jsonToFloat(d["restitution"]) ?? 0,
            gravityScale: jsonToFloat(d["gravityScale"]) ?? 1,
            vertexRadius: jsonToFloat(d["vertexRadius"]) ?? 0.02,
            solverIterations: jsonToInt(d["solverIterations"]) ?? 5,
            maxLinearVelocity: jsonToFloat(d["maxLinearVelocity"]) ?? 500,
            layerID: UInt16(clamping: jsonToInt(d["layerID"]) ?? 0),
            layerMask: UInt16(clamping: jsonToInt(d["layerMask"]) ?? Int(UInt16.max)),
            allowSleep: jsonToBool(d["allowSleep"]) ?? true,
            facesDoubleSided: jsonToBool(d["facesDoubleSided"]) ?? true,
            selfCollision: jsonToBool(d["selfCollision"]) ?? false,
            isEnabled: jsonToBool(d["isEnabled"]) ?? true
        )
    }

    static func serializeCloth(_ cloth: Cloth) -> [String: Any] {
        [
            "gridSizeX": cloth.gridSizeX,
            "gridSizeZ": cloth.gridSizeZ,
            "spacing": cloth.spacing,
            "fixedVertexIndices": cloth.fixedVertexIndices,
            "compliance": cloth.compliance,
            "shearCompliance": cloth.shearCompliance,
            "bendCompliance": cloth.bendCompliance,
            "bendType": cloth.bendType.rawValue,
        ]
    }

    static func deserializeCloth(_ d: [String: Any]) -> Cloth {
        Cloth(
            gridSizeX: jsonToInt(d["gridSizeX"]) ?? 16,
            gridSizeZ: jsonToInt(d["gridSizeZ"]) ?? 16,
            spacing: jsonToFloat(d["spacing"]) ?? 0.2,
            fixedVertexIndices: (jsonToArray(d["fixedVertexIndices"]) ?? []).compactMap(jsonToInt),
            compliance: jsonToFloat(d["compliance"]) ?? 1.0e-5,
            shearCompliance: jsonToFloat(d["shearCompliance"]) ?? 1.0e-5,
            bendCompliance: jsonToFloat(d["bendCompliance"]) ?? 1.0e-5,
            bendType: ClothBendType(
                rawValue: UInt8(clamping: jsonToInt(d["bendType"]) ?? 1)
            ) ?? .distance
        )
    }

    static func serializeSoftBodyMesh(_ mesh: SoftBodyMesh) -> [String: Any] {
        var result: [String: Any] = [
            "fixedVertexIndices": mesh.fixedVertexIndices,
            "compliance": mesh.compliance,
            "shearCompliance": mesh.shearCompliance,
            "bendCompliance": mesh.bendCompliance,
            "volumeCompliance": mesh.volumeCompliance,
            "bendType": mesh.bendType.rawValue,
        ]
        if let resourceID = mesh.resourceID {
            result["resourceID"] = resourceID
        }
        return result
    }

    static func deserializeSoftBodyMesh(_ d: [String: Any]) -> SoftBodyMesh {
        SoftBodyMesh(
            resourceID: jsonToString(d["resourceID"]),
            fixedVertexIndices: (jsonToArray(d["fixedVertexIndices"]) ?? []).compactMap(jsonToInt),
            compliance: jsonToFloat(d["compliance"]) ?? 1.0e-5,
            shearCompliance: jsonToFloat(d["shearCompliance"]) ?? 1.0e-5,
            bendCompliance: jsonToFloat(d["bendCompliance"]) ?? 1.0e-5,
            volumeCompliance: jsonToFloat(d["volumeCompliance"]) ?? 1.0e-6,
            bendType: ClothBendType(
                rawValue: UInt8(clamping: jsonToInt(d["bendType"]) ?? 2)
            ) ?? .dihedral
        )
    }

    static func serializeDestructible(_ destructible: Destructible) -> [String: Any] {
        [
            "assetResourceID": destructible.assetResourceID,
            "damageThreshold": destructible.damageThreshold,
            "impulseThreshold": destructible.impulseThreshold,
            "fragmentBudget": destructible.fragmentBudget,
            "maximumFragmentLifetimeSeconds": destructible.maximumFragmentLifetimeSeconds,
            "sleepingRecycleDelaySeconds": destructible.sleepingRecycleDelaySeconds,
            "separationImpulse": destructible.separationImpulse,
            "isEnabled": destructible.isEnabled,
        ]
    }

    static func deserializeDestructible(_ d: [String: Any]) -> Destructible {
        Destructible(
            assetResourceID: jsonToString(d["assetResourceID"]) ?? "",
            damageThreshold: jsonToFloat(d["damageThreshold"]) ?? 100,
            impulseThreshold: jsonToFloat(d["impulseThreshold"]) ?? 10,
            fragmentBudget: jsonToInt(d["fragmentBudget"]) ?? 256,
            maximumFragmentLifetimeSeconds: jsonToFloat(d["maximumFragmentLifetimeSeconds"]) ?? 30,
            sleepingRecycleDelaySeconds: jsonToFloat(d["sleepingRecycleDelaySeconds"]) ?? 5,
            separationImpulse: jsonToFloat(d["separationImpulse"]) ?? 0.05,
            isEnabled: jsonToBool(d["isEnabled"]) ?? true
        )
    }
}

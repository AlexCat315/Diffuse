#if canImport(Natsel)
import SIMDCompat
internal import Natsel

extension NatselPhysicsBackend {
    struct VehicleRecord {
        var id: Natsel.VehicleID
        var body: Natsel.BodyID
        var descriptor: PhysicsVehicleDescriptor
    }

    func synchronizeVehicles(_ context: PhysicsPrepareContext, result: inout PhysicsPrepareResult) throws {
        let active = Set(context.activeVehicles.filter { $0.vehicle.isEnabled }.map(\.entity))
        for entity in vehicles.keys.sorted(by: entityOrder) where !active.contains(entity) {
            if let old = vehicles.removeValue(forKey: entity) { world.destroyVehicle(old.id); result.removedVehicles += 1 }
        }
        for descriptor in context.activeVehicles.sorted(by: { entityOrder($0.entity, $1.entity) }) where descriptor.vehicle.isEnabled {
            guard let body = bodies[descriptor.entity] else { throw failure(.invalidArgument, "Vehicle requires a rigid body") }
            if let old = vehicles[descriptor.entity], old.body == body.id, old.descriptor == descriptor { continue }
            let config = descriptor.vehicle
            if case .tracked(let tracked) = config.controller {
                for track in [tracked.leftTrack, tracked.rightTrack] {
                    guard track.wheels.contains(track.drivenWheel), track.wheels.allSatisfy({ $0 >= 0 && $0 < config.wheels.count }) else {
                        throw failure(.invalidArgument, "Track must contain its driven wheel and reference valid wheels")
                    }
                }
            }
            var def = Natsel.VehicleDef()
            def.bodyId = body.id
            let collider = body.descriptor.collider
            def.filter = Natsel.QueryFilter(categoryBits: UInt64(1) << min(collider?.layerID ?? 0, 15),
                maskBits: UInt64(collider?.layerMask ?? .max))
            def.up = nv(config.up)
            def.forward = nv(config.forward)
            def.maxPitchRollAngle = config.maxPitchRollAngle
            def.collisionTester = .cylinder(convexRadiusFraction: 0.1)
            def.wheels = config.wheels.map { value in
                var wheel = Natsel.WheelSettings()
                wheel.position = nv(value.position)
                wheel.suspensionDirection = nv(value.suspensionDirection)
                wheel.steeringAxis = nv(value.steeringAxis)
                wheel.wheelUp = nv(value.wheelUp)
                wheel.wheelForward = nv(value.wheelForward)
                wheel.suspensionMinLength = value.suspensionMinLength
                wheel.suspensionMaxLength = value.suspensionMaxLength
                wheel.suspensionPreloadLength = value.suspensionPreloadLength
                wheel.suspensionFrequency = value.suspensionFrequency
                wheel.suspensionDampingRatio = value.suspensionDamping
                wheel.radius = value.radius
                wheel.width = value.width
                wheel.inertia = value.inertia
                wheel.angularDamping = value.angularDamping
                wheel.maxSteerAngle = value.maxSteerAngle
                wheel.maxBrakeTorque = value.maxBrakeTorque
                wheel.maxHandBrakeTorque = value.maxHandBrakeTorque
                if case .tracked(let tracked) = config.controller {
                    wheel.trackLongitudinalFriction = tracked.longitudinalFriction
                    wheel.trackLateralFriction = tracked.lateralFriction
                }
                return wheel
            }
            def.antiRollBars = config.antiRollBars.map { value in
                var bar = Natsel.VehicleAntiRollBar()
                bar.leftWheel = Int32(value.leftWheel)
                bar.rightWheel = Int32(value.rightWheel)
                bar.stiffness = value.stiffness
                return bar
            }
            var wheeled = Natsel.WheeledVehicleControllerSettings()
            wheeled.engine = vehicleEngine(config.engine)
            wheeled.transmission = vehicleTransmission(config.transmission)
            wheeled.differentials = config.differentials.map { value in
                var differential = Natsel.VehicleDifferentialSettings()
                differential.leftWheel = Int32(value.leftWheel)
                differential.rightWheel = Int32(value.rightWheel)
                differential.differentialRatio = value.differentialRatio
                differential.leftRightSplit = value.leftRightSplit
                differential.limitedSlipRatio = value.limitedSlipRatio
                differential.engineTorqueRatio = value.engineTorqueRatio
                return differential
            }
            switch config.controller {
            case .wheeled: def.controller = .wheeled(wheeled)
            case .motorcycle(let config):
                var motorcycle = Natsel.MotorcycleControllerSettings()
                motorcycle.wheeled = wheeled
                motorcycle.maxLeanAngle = config.maxLeanAngle
                motorcycle.leanSpringConstant = config.isLeanControllerEnabled ? config.leanSpringConstant : 0
                motorcycle.leanSpringDamping = config.leanSpringDamping
                motorcycle.leanSpringIntegrationCoefficient = config.leanSpringIntegrationCoefficient
                motorcycle.leanSpringIntegrationCoefficientDecay = config.leanSpringIntegrationCoefficientDecay
                motorcycle.leanSmoothingFactor = config.leanSmoothingFactor
                motorcycle.enableLeanSteeringLimit = config.isLeanSteeringLimitEnabled
                def.controller = .motorcycle(motorcycle)
            case .tracked(let config):
                var tracked = Natsel.TrackedVehicleControllerSettings()
                tracked.engine = wheeled.engine
                tracked.transmission = wheeled.transmission
                tracked.tracks = [config.leftTrack, config.rightTrack].map { value in
                    var track = Natsel.VehicleTrackSettings()
                    track.drivenWheel = Int32(value.drivenWheel)
                    track.wheels = value.wheels.map(Int32.init)
                    track.inertia = value.inertia
                    track.angularDamping = value.angularDamping
                    track.maxBrakeTorque = value.maxBrakeTorque
                    track.differentialRatio = value.differentialRatio
                    return track
                }
                def.controller = .tracked(tracked)
            }
            let id = world.createVehicle(def)
            guard world.vehicleIsValid(id) else { throw failure(.invalidArgument, "Invalid vehicle configuration") }
            if let old = vehicles.updateValue(VehicleRecord(id: id, body: body.id, descriptor: descriptor), forKey: descriptor.entity) { world.destroyVehicle(old.id) }
            result.synchronizedVehicles += 1
        }
    }

    func vehicleEngine(_ config: VehicleEngineConfiguration) -> Natsel.VehicleEngineSettings {
        var result = Natsel.VehicleEngineSettings()
        result.maxTorque = config.maxTorque
        result.minRPM = config.minRPM
        result.maxRPM = config.maxRPM
        result.inertia = config.inertia
        result.angularDamping = config.angularDamping
        return result
    }

    func vehicleTransmission(_ config: VehicleTransmissionConfiguration) -> Natsel.VehicleTransmissionSettings {
        var result = Natsel.VehicleTransmissionSettings()
        result.mode = config.mode == .manual ? .manual : .automatic
        result.gearRatios = config.gearRatios
        result.reverseGearRatios = config.reverseGearRatios
        result.switchTime = config.switchTime
        result.clutchReleaseTime = config.clutchReleaseTime
        result.switchLatency = config.switchLatency
        result.shiftUpRPM = config.shiftUpRPM
        result.shiftDownRPM = config.shiftDownRPM
        result.clutchStrength = config.clutchStrength
        return result
    }

    func applyVehicleCommands(_ context: PhysicsStepContext) {
        for entity in vehicles.keys.sorted(by: entityOrder) {
            let record = vehicles[entity]!
            let command = context.vehicleCommands[entity] ?? VehicleCommand()
            if case .tracked = record.descriptor.vehicle.controller {
                let magnitude = max(abs(command.throttle), abs(command.steering))
                let left = magnitude > 0 ? max(-1, min(1, (command.throttle + command.steering) / magnitude)) : 0
                let right = magnitude > 0 ? max(-1, min(1, (command.throttle - command.steering) / magnitude)) : 0
                world.setTrackedVehicleDriverInput(record.id, forward: magnitude, leftRatio: left, rightRatio: right, brake: command.brake)
            } else {
                world.setVehicleDriverInput(record.id, forward: command.throttle, right: command.steering,
                    brake: command.brake, handBrake: command.handBrake)
            }
            if let gear = command.manualGear { world.setVehicleTransmission(record.id, gear: Int32(clamping: gear), clutchFriction: command.clutch) }
        }
    }

    func vehicleStates() -> [VehicleState] {
        vehicles.keys.sorted(by: entityOrder).map { entity in
            let record = vehicles[entity]!
            let drivetrain = world.vehicleDrivetrainState(record.id)
            let wheels = (0..<world.vehicleWheelCount(record.id)).compactMap { index -> VehicleWheelState? in
                guard let state = world.vehicleWheelState(record.id, index), let pose = world.vehicleWheelTransform(record.id, index) else { return nil }
                return VehicleWheelState(index: Int(index), worldPosition: sv(pose.p), worldRotation: SIMD4(sv(pose.q.v), pose.q.s),
                    angularVelocity: state.angularVelocity, rotationAngle: state.rotationAngle, steerAngle: state.steerAngle,
                    suspensionLength: state.suspensionLength, hasContact: state.hasContact,
                    contactEntity: bodies.first { $0.value.id == state.contactBodyId }?.key,
                    contactPosition: sv(state.contactPosition), contactNormal: sv(state.contactNormal))
            }
            return VehicleState(entity: entity, forwardSpeed: world.vehicleForwardSpeed(record.id), engineRPM: drivetrain?.engineRPM ?? 0,
                currentGear: Int(drivetrain?.currentGear ?? 0), clutchFriction: drivetrain?.clutchFriction ?? 0, wheels: wheels)
        }
    }
}

#endif

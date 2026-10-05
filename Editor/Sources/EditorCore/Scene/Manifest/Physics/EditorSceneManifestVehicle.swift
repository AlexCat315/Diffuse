import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestVehicleWheel: Codable, Sendable, Equatable {
    public let position: EditorSceneManifestVector3
    public let suspensionDirection: EditorSceneManifestVector3
    public let steeringAxis: EditorSceneManifestVector3
    public let wheelUp: EditorSceneManifestVector3
    public let wheelForward: EditorSceneManifestVector3
    public let suspensionMinLength: Float
    public let suspensionMaxLength: Float
    public let suspensionPreloadLength: Float
    public let suspensionFrequency: Float
    public let suspensionDamping: Float
    public let radius: Float
    public let width: Float
    public let inertia: Float
    public let angularDamping: Float
    public let maxSteerAngle: Float
    public let maxBrakeTorque: Float
    public let maxHandBrakeTorque: Float

    public init(_ wheel: VehicleWheelConfiguration) {
        position = EditorSceneManifestVector3(wheel.position)
        suspensionDirection = EditorSceneManifestVector3(wheel.suspensionDirection)
        steeringAxis = EditorSceneManifestVector3(wheel.steeringAxis)
        wheelUp = EditorSceneManifestVector3(wheel.wheelUp)
        wheelForward = EditorSceneManifestVector3(wheel.wheelForward)
        suspensionMinLength = wheel.suspensionMinLength
        suspensionMaxLength = wheel.suspensionMaxLength
        suspensionPreloadLength = wheel.suspensionPreloadLength
        suspensionFrequency = wheel.suspensionFrequency
        suspensionDamping = wheel.suspensionDamping
        radius = wheel.radius
        width = wheel.width
        inertia = wheel.inertia
        angularDamping = wheel.angularDamping
        maxSteerAngle = wheel.maxSteerAngle
        maxBrakeTorque = wheel.maxBrakeTorque
        maxHandBrakeTorque = wheel.maxHandBrakeTorque
    }

    var component: VehicleWheelConfiguration {
        VehicleWheelConfiguration(
            position: position.simdValue,
            suspensionDirection: suspensionDirection.simdValue,
            steeringAxis: steeringAxis.simdValue,
            wheelUp: wheelUp.simdValue,
            wheelForward: wheelForward.simdValue,
            suspensionMinLength: suspensionMinLength,
            suspensionMaxLength: suspensionMaxLength,
            suspensionPreloadLength: suspensionPreloadLength,
            suspensionFrequency: suspensionFrequency,
            suspensionDamping: suspensionDamping,
            radius: radius,
            width: width,
            inertia: inertia,
            angularDamping: angularDamping,
            maxSteerAngle: maxSteerAngle,
            maxBrakeTorque: maxBrakeTorque,
            maxHandBrakeTorque: maxHandBrakeTorque
        )
    }
}

public struct EditorSceneManifestVehicleDifferential: Codable, Sendable, Equatable {
    public let leftWheel: Int
    public let rightWheel: Int
    public let differentialRatio: Float
    public let leftRightSplit: Float
    public let limitedSlipRatio: Float
    public let engineTorqueRatio: Float

    public init(_ value: VehicleDifferentialConfiguration) {
        leftWheel = value.leftWheel
        rightWheel = value.rightWheel
        differentialRatio = value.differentialRatio
        leftRightSplit = value.leftRightSplit
        limitedSlipRatio = value.limitedSlipRatio
        engineTorqueRatio = value.engineTorqueRatio
    }

    var component: VehicleDifferentialConfiguration {
        VehicleDifferentialConfiguration(
            leftWheel: leftWheel,
            rightWheel: rightWheel,
            differentialRatio: differentialRatio,
            leftRightSplit: leftRightSplit,
            limitedSlipRatio: limitedSlipRatio,
            engineTorqueRatio: engineTorqueRatio
        )
    }
}

public struct EditorSceneManifestVehicleAntiRollBar: Codable, Sendable, Equatable {
    public let leftWheel: Int
    public let rightWheel: Int
    public let stiffness: Float

    public init(_ value: VehicleAntiRollBarConfiguration) {
        leftWheel = value.leftWheel
        rightWheel = value.rightWheel
        stiffness = value.stiffness
    }

    var component: VehicleAntiRollBarConfiguration {
        VehicleAntiRollBarConfiguration(
            leftWheel: leftWheel, rightWheel: rightWheel, stiffness: stiffness
        )
    }
}

public struct EditorSceneManifestVehicleEngine: Codable, Sendable, Equatable {
    public let maxTorque: Float
    public let minRPM: Float
    public let maxRPM: Float
    public let inertia: Float
    public let angularDamping: Float

    public init(_ value: VehicleEngineConfiguration) {
        maxTorque = value.maxTorque
        minRPM = value.minRPM
        maxRPM = value.maxRPM
        inertia = value.inertia
        angularDamping = value.angularDamping
    }

    var component: VehicleEngineConfiguration {
        VehicleEngineConfiguration(
            maxTorque: maxTorque,
            minRPM: minRPM,
            maxRPM: maxRPM,
            inertia: inertia,
            angularDamping: angularDamping
        )
    }
}

public struct EditorSceneManifestVehicleTransmission: Codable, Sendable, Equatable {
    public let mode: String
    public let gearRatios: [Float]
    public let reverseGearRatios: [Float]
    public let switchTime: Float
    public let clutchReleaseTime: Float
    public let switchLatency: Float
    public let shiftUpRPM: Float
    public let shiftDownRPM: Float
    public let clutchStrength: Float

    public init(_ value: VehicleTransmissionConfiguration) {
        mode = value.mode == .automatic ? "automatic" : "manual"
        gearRatios = value.gearRatios
        reverseGearRatios = value.reverseGearRatios
        switchTime = value.switchTime
        clutchReleaseTime = value.clutchReleaseTime
        switchLatency = value.switchLatency
        shiftUpRPM = value.shiftUpRPM
        shiftDownRPM = value.shiftDownRPM
        clutchStrength = value.clutchStrength
    }

    var component: VehicleTransmissionConfiguration {
        VehicleTransmissionConfiguration(
            mode: mode == "manual" ? .manual : .automatic,
            gearRatios: gearRatios,
            reverseGearRatios: reverseGearRatios,
            switchTime: switchTime,
            clutchReleaseTime: clutchReleaseTime,
            switchLatency: switchLatency,
            shiftUpRPM: shiftUpRPM,
            shiftDownRPM: shiftDownRPM,
            clutchStrength: clutchStrength
        )
    }
}

public struct EditorSceneManifestVehicleTrack: Codable, Sendable, Equatable {
    public let drivenWheel: Int
    public let wheels: [Int]
    public let inertia: Float
    public let angularDamping: Float
    public let maxBrakeTorque: Float
    public let differentialRatio: Float

    public init(_ value: VehicleTrackConfiguration) {
        drivenWheel = value.drivenWheel
        wheels = value.wheels
        inertia = value.inertia
        angularDamping = value.angularDamping
        maxBrakeTorque = value.maxBrakeTorque
        differentialRatio = value.differentialRatio
    }

    var component: VehicleTrackConfiguration {
        VehicleTrackConfiguration(
            drivenWheel: drivenWheel,
            wheels: wheels,
            inertia: inertia,
            angularDamping: angularDamping,
            maxBrakeTorque: maxBrakeTorque,
            differentialRatio: differentialRatio
        )
    }
}

public struct EditorSceneManifestTrackedVehicle: Codable, Sendable, Equatable {
    public let leftTrack: EditorSceneManifestVehicleTrack
    public let rightTrack: EditorSceneManifestVehicleTrack
    public let longitudinalFriction: Float
    public let lateralFriction: Float

    public init(_ value: TrackedVehicleConfiguration) {
        leftTrack = EditorSceneManifestVehicleTrack(value.leftTrack)
        rightTrack = EditorSceneManifestVehicleTrack(value.rightTrack)
        longitudinalFriction = value.longitudinalFriction
        lateralFriction = value.lateralFriction
    }

    var component: TrackedVehicleConfiguration {
        TrackedVehicleConfiguration(
            leftTrack: leftTrack.component,
            rightTrack: rightTrack.component,
            longitudinalFriction: longitudinalFriction,
            lateralFriction: lateralFriction
        )
    }
}

public struct EditorSceneManifestMotorcycleVehicle: Codable, Sendable, Equatable {
    public let maxLeanAngle: Float
    public let leanSpringConstant: Float
    public let leanSpringDamping: Float
    public let leanSpringIntegrationCoefficient: Float
    public let leanSpringIntegrationCoefficientDecay: Float
    public let leanSmoothingFactor: Float
    public let isLeanControllerEnabled: Bool
    public let isLeanSteeringLimitEnabled: Bool

    public init(_ value: MotorcycleVehicleConfiguration) {
        maxLeanAngle = value.maxLeanAngle
        leanSpringConstant = value.leanSpringConstant
        leanSpringDamping = value.leanSpringDamping
        leanSpringIntegrationCoefficient = value.leanSpringIntegrationCoefficient
        leanSpringIntegrationCoefficientDecay = value.leanSpringIntegrationCoefficientDecay
        leanSmoothingFactor = value.leanSmoothingFactor
        isLeanControllerEnabled = value.isLeanControllerEnabled
        isLeanSteeringLimitEnabled = value.isLeanSteeringLimitEnabled
    }

    var component: MotorcycleVehicleConfiguration {
        MotorcycleVehicleConfiguration(
            maxLeanAngle: maxLeanAngle,
            leanSpringConstant: leanSpringConstant,
            leanSpringDamping: leanSpringDamping,
            leanSpringIntegrationCoefficient: leanSpringIntegrationCoefficient,
            leanSpringIntegrationCoefficientDecay: leanSpringIntegrationCoefficientDecay,
            leanSmoothingFactor: leanSmoothingFactor,
            isLeanControllerEnabled: isLeanControllerEnabled,
            isLeanSteeringLimitEnabled: isLeanSteeringLimitEnabled
        )
    }
}

public struct EditorSceneManifestVehicle: Codable, Sendable, Equatable {
    public let controllerKind: String?
    public let tracked: EditorSceneManifestTrackedVehicle?
    public let motorcycle: EditorSceneManifestMotorcycleVehicle?
    public let wheels: [EditorSceneManifestVehicleWheel]
    public let differentials: [EditorSceneManifestVehicleDifferential]
    public let antiRollBars: [EditorSceneManifestVehicleAntiRollBar]
    public let engine: EditorSceneManifestVehicleEngine
    public let transmission: EditorSceneManifestVehicleTransmission
    public let up: EditorSceneManifestVector3
    public let forward: EditorSceneManifestVector3
    public let maxPitchRollAngle: Float
    public let isEnabled: Bool

    public init(_ vehicle: Vehicle) {
        controllerKind = String(describing: vehicle.controller.kind)
        if case let .tracked(configuration) = vehicle.controller {
            tracked = EditorSceneManifestTrackedVehicle(configuration)
        } else {
            tracked = nil
        }
        if case let .motorcycle(configuration) = vehicle.controller {
            motorcycle = EditorSceneManifestMotorcycleVehicle(configuration)
        } else {
            motorcycle = nil
        }
        wheels = vehicle.wheels.map(EditorSceneManifestVehicleWheel.init)
        differentials = vehicle.differentials.map(EditorSceneManifestVehicleDifferential.init)
        antiRollBars = vehicle.antiRollBars.map(EditorSceneManifestVehicleAntiRollBar.init)
        engine = EditorSceneManifestVehicleEngine(vehicle.engine)
        transmission = EditorSceneManifestVehicleTransmission(vehicle.transmission)
        up = EditorSceneManifestVector3(vehicle.up)
        forward = EditorSceneManifestVector3(vehicle.forward)
        maxPitchRollAngle = vehicle.maxPitchRollAngle
        isEnabled = vehicle.isEnabled
    }

    var component: Vehicle {
        let controller: VehicleControllerConfiguration
        switch controllerKind {
        case "tracked":
            controller = tracked.map { .tracked($0.component) } ?? Vehicle.tracked().controller
        case "motorcycle":
            controller = .motorcycle(motorcycle?.component ?? MotorcycleVehicleConfiguration())
        default:
            controller = .wheeled
        }
        return Vehicle(
            controller: controller,
            wheels: wheels.map(\.component),
            differentials: differentials.map(\.component),
            antiRollBars: antiRollBars.map(\.component),
            engine: engine.component,
            transmission: transmission.component,
            up: up.simdValue,
            forward: forward.simdValue,
            maxPitchRollAngle: maxPitchRollAngle,
            isEnabled: isEnabled
        )
    }
}

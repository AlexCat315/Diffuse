import Foundation
import SIMDCompat

/// A Jolt vehicle attached to the same entity's dynamic `RigidBody`.
public struct Vehicle: RuntimeComponent, Sendable, Equatable {
    public var controller: VehicleControllerConfiguration
    public var wheels: [VehicleWheelConfiguration]
    public var differentials: [VehicleDifferentialConfiguration]
    public var antiRollBars: [VehicleAntiRollBarConfiguration]
    public var engine: VehicleEngineConfiguration
    public var transmission: VehicleTransmissionConfiguration
    public var up: SIMD3<Float>
    public var forward: SIMD3<Float>
    public var maxPitchRollAngle: Float
    public var isEnabled: Bool

    public init(
        controller: VehicleControllerConfiguration = .wheeled,
        wheels: [VehicleWheelConfiguration] = Vehicle.defaultWheels,
        differentials: [VehicleDifferentialConfiguration] = [
            VehicleDifferentialConfiguration(leftWheel: 2, rightWheel: 3)
        ],
        antiRollBars: [VehicleAntiRollBarConfiguration] = [
            VehicleAntiRollBarConfiguration(leftWheel: 0, rightWheel: 1),
            VehicleAntiRollBarConfiguration(leftWheel: 2, rightWheel: 3),
        ],
        engine: VehicleEngineConfiguration = VehicleEngineConfiguration(),
        transmission: VehicleTransmissionConfiguration = VehicleTransmissionConfiguration(),
        up: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        forward: SIMD3<Float> = SIMD3<Float>(0, 0, 1),
        maxPitchRollAngle: Float = .pi,
        isEnabled: Bool = true
    ) {
        self.controller = controller
        self.wheels = wheels
        self.differentials = differentials
        self.antiRollBars = antiRollBars
        self.engine = engine
        self.transmission = transmission
        self.up = up
        self.forward = forward
        self.maxPitchRollAngle = max(0, min(maxPitchRollAngle, .pi))
        self.isEnabled = isEnabled
    }

    public static let defaultWheels: [VehicleWheelConfiguration] = [
        VehicleWheelConfiguration(position: SIMD3<Float>(0.9, -0.2, 1.4), maxSteerAngle: .pi / 4),
        VehicleWheelConfiguration(position: SIMD3<Float>(-0.9, -0.2, 1.4), maxSteerAngle: .pi / 4),
        VehicleWheelConfiguration(position: SIMD3<Float>(0.9, -0.2, -1.4), maxHandBrakeTorque: 4_000),
        VehicleWheelConfiguration(position: SIMD3<Float>(-0.9, -0.2, -1.4), maxHandBrakeTorque: 4_000),
    ]

    public static func tracked(
        engine: VehicleEngineConfiguration = VehicleEngineConfiguration(maxTorque: 1_500),
        transmission: VehicleTransmissionConfiguration = VehicleTransmissionConfiguration()
    ) -> Vehicle {
        let wheels = [
            VehicleWheelConfiguration(position: SIMD3<Float>(0.9, -0.25, 1.2), width: 0.35),
            VehicleWheelConfiguration(position: SIMD3<Float>(0.9, -0.25, 0), width: 0.35),
            VehicleWheelConfiguration(position: SIMD3<Float>(0.9, -0.25, -1.2), width: 0.35),
            VehicleWheelConfiguration(position: SIMD3<Float>(-0.9, -0.25, 1.2), width: 0.35),
            VehicleWheelConfiguration(position: SIMD3<Float>(-0.9, -0.25, 0), width: 0.35),
            VehicleWheelConfiguration(position: SIMD3<Float>(-0.9, -0.25, -1.2), width: 0.35),
        ]
        let tracked = TrackedVehicleConfiguration(
            leftTrack: VehicleTrackConfiguration(drivenWheel: 2, wheels: [0, 1, 2]),
            rightTrack: VehicleTrackConfiguration(drivenWheel: 5, wheels: [3, 4, 5])
        )
        return Vehicle(
            controller: .tracked(tracked),
            wheels: wheels,
            differentials: [],
            antiRollBars: [],
            engine: engine,
            transmission: transmission,
            maxPitchRollAngle: .pi / 3
        )
    }

    public static func motorcycle(
        configuration: MotorcycleVehicleConfiguration = MotorcycleVehicleConfiguration(),
        engine: VehicleEngineConfiguration = VehicleEngineConfiguration(
            maxTorque: 150, minRPM: 1_000, maxRPM: 10_000
        ),
        transmission: VehicleTransmissionConfiguration = VehicleTransmissionConfiguration(
            gearRatios: [2.27, 1.63, 1.3, 1.09, 0.96, 0.88],
            reverseGearRatios: [-4],
            shiftUpRPM: 8_000,
            shiftDownRPM: 2_000,
            clutchStrength: 2
        )
    ) -> Vehicle {
        let front = VehicleWheelConfiguration(
            position: SIMD3<Float>(0, -0.25, 0.75),
            suspensionDirection: SIMD3<Float>(0, -0.866_025_4, 0.5),
            steeringAxis: SIMD3<Float>(0, 0.866_025_4, -0.5),
            suspensionMinLength: 0.3,
            suspensionMaxLength: 0.5,
            suspensionFrequency: 1.5,
            radius: 0.31,
            width: 0.08,
            maxSteerAngle: .pi / 6,
            maxBrakeTorque: 500
        )
        let rear = VehicleWheelConfiguration(
            position: SIMD3<Float>(0, -0.25, -0.75),
            suspensionMinLength: 0.3,
            suspensionMaxLength: 0.5,
            suspensionFrequency: 2,
            radius: 0.31,
            width: 0.08,
            maxBrakeTorque: 250
        )
        return Vehicle(
            controller: .motorcycle(configuration),
            wheels: [front, rear],
            differentials: [
                VehicleDifferentialConfiguration(
                    leftWheel: -1,
                    rightWheel: 1,
                    differentialRatio: 4.825
                )
            ],
            antiRollBars: [],
            engine: engine,
            transmission: transmission,
            maxPitchRollAngle: .pi / 3
        )
    }
}

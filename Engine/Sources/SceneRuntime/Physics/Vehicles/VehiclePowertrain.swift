import Foundation
import SIMDCompat

public struct VehicleEngineConfiguration: Sendable, Equatable {
    public var maxTorque: Float
    public var minRPM: Float
    public var maxRPM: Float
    public var inertia: Float
    public var angularDamping: Float

    public init(
        maxTorque: Float = 500,
        minRPM: Float = 1_000,
        maxRPM: Float = 6_000,
        inertia: Float = 0.5,
        angularDamping: Float = 0.2
    ) {
        self.maxTorque = max(0, maxTorque)
        self.minRPM = max(0, minRPM)
        self.maxRPM = max(self.minRPM, maxRPM)
        self.inertia = max(0.001, inertia)
        self.angularDamping = max(0, angularDamping)
    }
}

public struct VehicleTransmissionConfiguration: Sendable, Equatable {
    public var mode: VehicleTransmissionMode
    public var gearRatios: [Float]
    public var reverseGearRatios: [Float]
    public var switchTime: Float
    public var clutchReleaseTime: Float
    public var switchLatency: Float
    public var shiftUpRPM: Float
    public var shiftDownRPM: Float
    public var clutchStrength: Float

    public init(
        mode: VehicleTransmissionMode = .automatic,
        gearRatios: [Float] = [2.66, 1.78, 1.3, 1, 0.74],
        reverseGearRatios: [Float] = [-2.9],
        switchTime: Float = 0.5,
        clutchReleaseTime: Float = 0.3,
        switchLatency: Float = 0.5,
        shiftUpRPM: Float = 4_000,
        shiftDownRPM: Float = 2_000,
        clutchStrength: Float = 10
    ) {
        self.mode = mode
        self.gearRatios = gearRatios.isEmpty ? [1] : gearRatios
        self.reverseGearRatios = reverseGearRatios.isEmpty ? [-1] : reverseGearRatios
        self.switchTime = max(0, switchTime)
        self.clutchReleaseTime = max(0, clutchReleaseTime)
        self.switchLatency = max(0, switchLatency)
        self.shiftUpRPM = max(0, shiftUpRPM)
        self.shiftDownRPM = max(0, min(shiftDownRPM, self.shiftUpRPM))
        self.clutchStrength = max(0, clutchStrength)
    }
}

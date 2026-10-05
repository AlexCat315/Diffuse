import Foundation
import SIMDCompat

public struct PhysicsRecordedBodyCommand: Sendable, Equatable {
    public var entity: EntityID
    public var force: SIMD3<Float>
    public var torque: SIMD3<Float>
    public var linearImpulse: SIMD3<Float>
    public var angularImpulse: SIMD3<Float>
    public var wake: Bool

    public init(
        entity: EntityID,
        force: SIMD3<Float> = .zero,
        torque: SIMD3<Float> = .zero,
        linearImpulse: SIMD3<Float> = .zero,
        angularImpulse: SIMD3<Float> = .zero,
        wake: Bool = true
    ) {
        self.entity = entity
        self.force = force
        self.torque = torque
        self.linearImpulse = linearImpulse
        self.angularImpulse = angularImpulse
        self.wake = wake
    }
}

public struct PhysicsRecordedCharacterCommand: Sendable, Equatable {
    public var entity: EntityID
    public var command: CharacterCommand

    public init(entity: EntityID, command: CharacterCommand) {
        self.entity = entity
        self.command = command
    }
}

public struct PhysicsRecordedVehicleCommand: Sendable, Equatable {
    public var entity: EntityID
    public var command: VehicleCommand

    public init(entity: EntityID, command: VehicleCommand) {
        self.entity = entity
        self.command = command
    }
}

public struct PhysicsCommandFrame: Sendable, Equatable {
    public var deltaTimeSeconds: Double
    public var settings: PhysicsSettingsResource
    public var bodyCommands: [PhysicsRecordedBodyCommand]
    public var characterCommands: [PhysicsRecordedCharacterCommand]
    public var vehicleCommands: [PhysicsRecordedVehicleCommand]
    public var destructionCommands: [DestructionCommand]
    public var expectedSimulatedStep: Int
    public var expectedStateHash: UInt64

    public init(
        deltaTimeSeconds: Double,
        settings: PhysicsSettingsResource,
        bodyCommands: [PhysicsRecordedBodyCommand] = [],
        characterCommands: [PhysicsRecordedCharacterCommand] = [],
        vehicleCommands: [PhysicsRecordedVehicleCommand] = [],
        destructionCommands: [DestructionCommand] = [],
        expectedSimulatedStep: Int,
        expectedStateHash: UInt64
    ) {
        self.deltaTimeSeconds = max(0, deltaTimeSeconds)
        self.settings = settings
        self.bodyCommands = bodyCommands.sorted { $0.entity.rawValue < $1.entity.rawValue }
        self.characterCommands = characterCommands.sorted { $0.entity.rawValue < $1.entity.rawValue }
        self.vehicleCommands = vehicleCommands.sorted { $0.entity.rawValue < $1.entity.rawValue }
        self.destructionCommands = destructionCommands.enumerated().sorted {
            ($0.element.entity.rawValue, $0.offset) < ($1.element.entity.rawValue, $1.offset)
        }.map(\.element)
        self.expectedSimulatedStep = expectedSimulatedStep
        self.expectedStateHash = expectedStateHash
    }
}

public struct PhysicsCommandTape: Sendable, Equatable {
    public var frames: [PhysicsCommandFrame]

    public init(frames: [PhysicsCommandFrame] = []) {
        self.frames = frames
    }
}

public struct PhysicsCommandRecordingResource: Sendable, Equatable {
    public var isRecording: Bool
    public var maxFrames: Int
    public var frames: [PhysicsCommandFrame]

    public init(isRecording: Bool = false, maxFrames: Int = 36_000, frames: [PhysicsCommandFrame] = []) {
        self.isRecording = isRecording
        self.maxFrames = max(1, maxFrames)
        self.frames = Array(frames.prefix(max(1, maxFrames)))
    }

    public static let inactive = PhysicsCommandRecordingResource()
}

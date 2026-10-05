import Foundation
import SIMDCompat

public struct PhysicsCapacitySettings: Sendable, Equatable, Codable {
    public var maxBodies: Int
    public var bodyMutexCount: Int
    public var maxBodyPairs: Int
    public var maxContactConstraints: Int
    public var tempAllocatorBytes: Int
    /// Zero selects the platform default: the available logical core count minus one.
    public var workerThreadCount: Int

    public init(
        maxBodies: Int = 65_536,
        bodyMutexCount: Int = 0,
        maxBodyPairs: Int = 65_536,
        maxContactConstraints: Int = 10_240,
        tempAllocatorBytes: Int = 10 * 1_024 * 1_024,
        workerThreadCount: Int = 0
    ) {
        self.maxBodies = min(Int(UInt32.max), max(1, maxBodies))
        self.bodyMutexCount = min(Int(UInt32.max), max(0, bodyMutexCount))
        self.maxBodyPairs = min(Int(UInt32.max), max(1, maxBodyPairs))
        self.maxContactConstraints = min(Int(UInt32.max), max(1, maxContactConstraints))
        self.tempAllocatorBytes = min(Int(UInt32.max), max(1_024 * 1_024, tempAllocatorBytes))
        self.workerThreadCount = min(1_024, max(0, workerThreadCount))
    }

    private enum CodingKeys: String, CodingKey {
        case maxBodies
        case bodyMutexCount
        case maxBodyPairs
        case maxContactConstraints
        case tempAllocatorBytes
        case workerThreadCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PhysicsCapacitySettings()
        self.init(
            maxBodies: try values.decodeIfPresent(Int.self, forKey: .maxBodies) ?? defaults.maxBodies,
            bodyMutexCount: try values.decodeIfPresent(Int.self, forKey: .bodyMutexCount) ?? defaults.bodyMutexCount,
            maxBodyPairs: try values.decodeIfPresent(Int.self, forKey: .maxBodyPairs) ?? defaults.maxBodyPairs,
            maxContactConstraints: try values.decodeIfPresent(Int.self, forKey: .maxContactConstraints)
                ?? defaults.maxContactConstraints,
            tempAllocatorBytes: try values.decodeIfPresent(Int.self, forKey: .tempAllocatorBytes)
                ?? defaults.tempAllocatorBytes,
            workerThreadCount: try values.decodeIfPresent(Int.self, forKey: .workerThreadCount)
                ?? defaults.workerThreadCount
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(maxBodies, forKey: .maxBodies)
        try values.encode(bodyMutexCount, forKey: .bodyMutexCount)
        try values.encode(maxBodyPairs, forKey: .maxBodyPairs)
        try values.encode(maxContactConstraints, forKey: .maxContactConstraints)
        try values.encode(tempAllocatorBytes, forKey: .tempAllocatorBytes)
        try values.encode(workerThreadCount, forKey: .workerThreadCount)
    }
}

public struct PhysicsSettingsResource: Sendable, Equatable {
    public var simulationMode: PhysicsSimulationMode
    public var backendKind: PhysicsBackendKind
    public var gravity: SIMD3<Float>
    public var fixedTimeStepSeconds: Double
    public var maxSubstepsPerFrame: Int
    public var allowSleep: Bool
    public var collisionSteps: Int
    public var capacity: PhysicsCapacitySettings

    public init(
        simulationMode: PhysicsSimulationMode = .off,
        backendKind: PhysicsBackendKind = .jolt,
        gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0),
        fixedTimeStepSeconds: Double = 1.0 / 60.0,
        maxSubstepsPerFrame: Int = 4,
        allowSleep: Bool = true,
        collisionSteps: Int = 1,
        capacity: PhysicsCapacitySettings = PhysicsCapacitySettings()
    ) {
        self.simulationMode = simulationMode
        self.backendKind = backendKind
        self.gravity = gravity
        self.fixedTimeStepSeconds = max(0.000_001, fixedTimeStepSeconds)
        self.maxSubstepsPerFrame = max(1, maxSubstepsPerFrame)
        self.allowSleep = allowSleep
        self.collisionSteps = max(1, collisionSteps)
        self.capacity = PhysicsCapacitySettings(
            maxBodies: capacity.maxBodies,
            bodyMutexCount: capacity.bodyMutexCount,
            maxBodyPairs: capacity.maxBodyPairs,
            maxContactConstraints: capacity.maxContactConstraints,
            tempAllocatorBytes: capacity.tempAllocatorBytes,
            workerThreadCount: capacity.workerThreadCount
        )
    }
}

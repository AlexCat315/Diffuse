import Foundation
import SIMDCompat

/// Capacity limits every backend honors. Engine-specific tuning lives in the
/// backend's own settings group.
public struct PhysicsCapacitySettings: Sendable, Equatable, Codable {
    public var maxBodies: Int
    /// Zero selects the platform default: the available logical core count minus one.
    public var workerThreadCount: Int

    public init(maxBodies: Int = 65_536, workerThreadCount: Int = 0) {
        self.maxBodies = min(Int(UInt32.max), max(1, maxBodies))
        self.workerThreadCount = min(1_024, max(0, workerThreadCount))
    }

    private enum CodingKeys: String, CodingKey {
        case maxBodies
        case workerThreadCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = PhysicsCapacitySettings()
        self.init(
            maxBodies: try values.decodeIfPresent(Int.self, forKey: .maxBodies) ?? defaults.maxBodies,
            workerThreadCount: try values.decodeIfPresent(Int.self, forKey: .workerThreadCount)
                ?? defaults.workerThreadCount
        )
    }

    func validated() -> PhysicsCapacitySettings {
        PhysicsCapacitySettings(maxBodies: maxBodies, workerThreadCount: workerThreadCount)
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
    public var jolt: JoltPhysicsTuning

    public init(
        simulationMode: PhysicsSimulationMode = .off,
        backendKind: PhysicsBackendKind = .preferred,
        gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0),
        fixedTimeStepSeconds: Double = 1.0 / 60.0,
        maxSubstepsPerFrame: Int = 4,
        allowSleep: Bool = true,
        collisionSteps: Int = 1,
        capacity: PhysicsCapacitySettings = PhysicsCapacitySettings(),
        jolt: JoltPhysicsTuning = JoltPhysicsTuning()
    ) {
        self.simulationMode = simulationMode
        self.backendKind = backendKind
        self.gravity = gravity
        self.fixedTimeStepSeconds = max(0.000_001, fixedTimeStepSeconds)
        self.maxSubstepsPerFrame = max(1, maxSubstepsPerFrame)
        self.allowSleep = allowSleep
        self.collisionSteps = max(1, collisionSteps)
        self.capacity = capacity.validated()
        self.jolt = jolt.validated()
    }
}

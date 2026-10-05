import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

public struct EditorSceneManifestPhysicsSettings: Codable, Sendable, Equatable {
    public let simulationMode: String
    public let backendKind: String
    public let gravity: EditorSceneManifestVector3
    public let fixedTimeStepSeconds: Double
    public let maxSubstepsPerFrame: Int
    public let allowSleep: Bool
    public let collisionSteps: Int
    public let capacity: PhysicsCapacitySettings

    private enum CodingKeys: String, CodingKey {
        case simulationMode
        case backendKind
        case gravity
        case fixedTimeStepSeconds
        case maxSubstepsPerFrame
        case allowSleep
        case collisionSteps
        case capacity
    }

    public init(_ settings: PhysicsSettingsResource) {
        self.simulationMode = settings.simulationMode.rawValue
        self.backendKind = settings.backendKind.rawValue
        self.gravity = EditorSceneManifestVector3(settings.gravity)
        self.fixedTimeStepSeconds = settings.fixedTimeStepSeconds
        self.maxSubstepsPerFrame = settings.maxSubstepsPerFrame
        self.allowSleep = settings.allowSleep
        self.collisionSteps = settings.collisionSteps
        self.capacity = settings.capacity
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        simulationMode = try c.decode(String.self, forKey: .simulationMode)
        backendKind = try c.decodeIfPresent(String.self, forKey: .backendKind)
            ?? PhysicsBackendKind.jolt.rawValue
        gravity = try c.decode(EditorSceneManifestVector3.self, forKey: .gravity)
        fixedTimeStepSeconds = try c.decode(Double.self, forKey: .fixedTimeStepSeconds)
        maxSubstepsPerFrame = try c.decode(Int.self, forKey: .maxSubstepsPerFrame)
        allowSleep = try c.decode(Bool.self, forKey: .allowSleep)
        collisionSteps = try c.decodeIfPresent(Int.self, forKey: .collisionSteps) ?? 1
        capacity = try c.decodeIfPresent(PhysicsCapacitySettings.self, forKey: .capacity)
            ?? PhysicsCapacitySettings()
    }

    var settings: PhysicsSettingsResource {
        PhysicsSettingsResource(
            simulationMode: PhysicsSimulationMode(rawValue: simulationMode) ?? .off,
            backendKind: .jolt,
            gravity: gravity.simdValue,
            fixedTimeStepSeconds: fixedTimeStepSeconds,
            maxSubstepsPerFrame: maxSubstepsPerFrame,
            allowSleep: allowSleep,
            collisionSteps: collisionSteps,
            capacity: capacity
        )
    }
}

public struct EditorSceneManifestParticleScalability: Codable, Sendable, Equatable {
    public let emissionScale: Float
    public let burstScale: Float
    public let distanceEmissionScale: Float
    public let maxLiveParticleScale: Float

    public init(_ settings: ParticleScalabilityResource) {
        self.emissionScale = settings.emissionScale
        self.burstScale = settings.burstScale
        self.distanceEmissionScale = settings.distanceEmissionScale
        self.maxLiveParticleScale = settings.maxLiveParticleScale
    }

    var settings: ParticleScalabilityResource {
        ParticleScalabilityResource(emissionScale: emissionScale,
                                    burstScale: burstScale,
                                    distanceEmissionScale: distanceEmissionScale,
                                    maxLiveParticleScale: maxLiveParticleScale)
    }
}

public struct EditorSceneManifestParticleScalabilityPolicy: Codable, Sendable, Equatable {
    public let isEnabled: Bool
    public let targetLiveParticles: Int
    public let targetSpawnedParticlesPerFrame: Int
    public let minimumScale: Float
    public let pressureStep: Float
    public let recoveryStep: Float

    public init(_ policy: ParticleScalabilityPolicyResource) {
        self.isEnabled = policy.isEnabled
        self.targetLiveParticles = policy.targetLiveParticles
        self.targetSpawnedParticlesPerFrame = policy.targetSpawnedParticlesPerFrame
        self.minimumScale = policy.minimumScale
        self.pressureStep = policy.pressureStep
        self.recoveryStep = policy.recoveryStep
    }

    var policy: ParticleScalabilityPolicyResource {
        ParticleScalabilityPolicyResource(isEnabled: isEnabled,
                                          targetLiveParticles: targetLiveParticles,
                                          targetSpawnedParticlesPerFrame: targetSpawnedParticlesPerFrame,
                                          minimumScale: minimumScale,
                                          pressureStep: pressureStep,
                                          recoveryStep: recoveryStep)
    }
}

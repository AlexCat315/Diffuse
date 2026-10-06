import EngineKernel
import SIMDCompat

public enum ParticleGPUSimulationPlanStatus: String, Codable, Sendable, Equatable, Hashable {
    case disabled
    case supported
    case fallbackToCPU
    case requiredButUnsupported
}

public enum ParticleGPUSimulationUnsupportedReason: String, Codable, Sendable, Equatable, Hashable {
    case backendCPU
    case noParticleCapacity
    case eventSubEmitters
    case distanceEmission
    case noise
    case forceFields
    case collisions
    case angularVelocity
}

public struct ParticleGPUSimulationPlan: Sendable, Equatable {
    public static let maximumWorkgroupSize = 256

    public var backend: ParticleSimulationBackend
    public var status: ParticleGPUSimulationPlanStatus
    public var particleCapacity: Int
    public var workgroupSize: Int
    public var dispatchWorkgroups: Int
    public var unsupportedReasons: [ParticleGPUSimulationUnsupportedReason]

    public init(emitter: ParticleEmitter) {
        self.backend = emitter.settings.gpuSimulation.simulationBackend
        self.particleCapacity = max(0, emitter.settings.emission.maxParticles)
        self.workgroupSize = min(
            max(1, emitter.settings.gpuSimulation.workgroupSize),
            Self.maximumWorkgroupSize
        )
        self.dispatchWorkgroups = particleCapacity > 0
            ? Int(ceil(Float(particleCapacity) / Float(workgroupSize)))
            : 0

        var reasons: [ParticleGPUSimulationUnsupportedReason] = []
        if emitter.settings.gpuSimulation.simulationBackend == .cpu {
            reasons.append(.backendCPU)
        }
        if particleCapacity == 0 {
            reasons.append(.noParticleCapacity)
        }
        self.unsupportedReasons = reasons

        if emitter.settings.gpuSimulation.simulationBackend == .cpu {
            self.status = .disabled
        } else if reasons.isEmpty {
            self.status = .supported
        } else if emitter.settings.gpuSimulation.simulationBackend == .gpuRequired {
            self.status = .requiredButUnsupported
        } else {
            self.status = .fallbackToCPU
        }
    }

    public var usesGPU: Bool {
        status == .supported
    }
}

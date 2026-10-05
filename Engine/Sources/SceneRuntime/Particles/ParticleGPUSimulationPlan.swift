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
        self.backend = emitter.simulationBackend
        self.particleCapacity = max(0, emitter.maxParticles)
        self.workgroupSize = min(
            max(1, emitter.gpuSimulationWorkgroupSize),
            Self.maximumWorkgroupSize
        )
        self.dispatchWorkgroups = particleCapacity > 0
            ? Int(ceil(Float(particleCapacity) / Float(workgroupSize)))
            : 0

        var reasons: [ParticleGPUSimulationUnsupportedReason] = []
        if emitter.simulationBackend == .cpu {
            reasons.append(.backendCPU)
        }
        if particleCapacity == 0 {
            reasons.append(.noParticleCapacity)
        }
        self.unsupportedReasons = reasons

        if emitter.simulationBackend == .cpu {
            self.status = .disabled
        } else if reasons.isEmpty {
            self.status = .supported
        } else if emitter.simulationBackend == .gpuRequired {
            self.status = .requiredButUnsupported
        } else {
            self.status = .fallbackToCPU
        }
    }

    public var usesGPU: Bool {
        status == .supported
    }
}

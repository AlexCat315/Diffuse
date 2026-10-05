import EngineKernel
import SIMDCompat

public struct ParticleScalabilityResource: Sendable, Equatable {
    public var emissionScale: Float
    public var burstScale: Float
    public var distanceEmissionScale: Float
    public var maxLiveParticleScale: Float

    public init(emissionScale: Float = 1,
                burstScale: Float = 1,
                distanceEmissionScale: Float = 1,
                maxLiveParticleScale: Float = 1) {
        let options = ParticleAdvanceOptions(emissionScale: emissionScale,
                                             burstScale: burstScale,
                                             distanceEmissionScale: distanceEmissionScale,
                                             maxLiveParticleScale: maxLiveParticleScale)
        self.emissionScale = options.emissionScale
        self.burstScale = options.burstScale
        self.distanceEmissionScale = options.distanceEmissionScale
        self.maxLiveParticleScale = options.maxLiveParticleScale
    }

    public static let `default` = ParticleScalabilityResource()

    public var advanceOptions: ParticleAdvanceOptions {
        ParticleAdvanceOptions(emissionScale: emissionScale,
                               burstScale: burstScale,
                               distanceEmissionScale: distanceEmissionScale,
                               maxLiveParticleScale: maxLiveParticleScale)
    }
}

public enum ParticleScalabilityPressureReason: String, CaseIterable, Sendable, Equatable {
    case none
    case liveBudget
    case spawnBudget
    case capacityLimited
}

public enum ParticleRuntimePressureLevel: String, CaseIterable, Sendable, Equatable {
    case idle
    case nominal
    case warning
    case critical
}

func dominantParticleRuntimePressureLevel(_ lhs: ParticleRuntimePressureLevel,
                                                  _ rhs: ParticleRuntimePressureLevel) -> ParticleRuntimePressureLevel {
    particleRuntimePressureRank(lhs) >= particleRuntimePressureRank(rhs) ? lhs : rhs
}

private func particleRuntimePressureRank(_ level: ParticleRuntimePressureLevel) -> Int {
    switch level {
    case .idle:
        return 0
    case .nominal:
        return 1
    case .warning:
        return 2
    case .critical:
        return 3
    }
}

public struct ParticleScalabilityStateResource: Sendable, Equatable {
    public var appliedScale: Float
    public var pressure: Float
    public var reason: ParticleScalabilityPressureReason

    public init(appliedScale: Float = 1,
                pressure: Float = 0,
                reason: ParticleScalabilityPressureReason = .none) {
        self.appliedScale = simd_clamp(appliedScale, 0, 1)
        self.pressure = simd_clamp(pressure, 0, 10)
        self.reason = reason
    }

    public static let `default` = ParticleScalabilityStateResource()

    public func applying(to base: ParticleAdvanceOptions) -> ParticleAdvanceOptions {
        ParticleAdvanceOptions(emissionScale: base.emissionScale * appliedScale,
                               burstScale: base.burstScale * appliedScale,
                               distanceEmissionScale: base.distanceEmissionScale * appliedScale,
                               maxLiveParticleScale: base.maxLiveParticleScale * appliedScale)
    }
}

public struct ParticleScalabilityPolicyResource: Sendable, Equatable {
    public var isEnabled: Bool
    public var targetLiveParticles: Int
    public var targetSpawnedParticlesPerFrame: Int
    public var minimumScale: Float
    public var pressureStep: Float
    public var recoveryStep: Float

    public init(isEnabled: Bool = false,
                targetLiveParticles: Int = 0,
                targetSpawnedParticlesPerFrame: Int = 0,
                minimumScale: Float = 0.25,
                pressureStep: Float = 0.15,
                recoveryStep: Float = 0.05) {
        self.isEnabled = isEnabled
        self.targetLiveParticles = max(0, targetLiveParticles)
        self.targetSpawnedParticlesPerFrame = max(0, targetSpawnedParticlesPerFrame)
        self.minimumScale = simd_clamp(minimumScale, 0, 1)
        self.pressureStep = simd_clamp(pressureStep, 0, 1)
        self.recoveryStep = simd_clamp(recoveryStep, 0, 1)
    }

    public static let disabled = ParticleScalabilityPolicyResource()

    public func updatedState(previousStats: ParticleFrameStatsResource,
                             previousState: ParticleScalabilityStateResource = .default)
        -> ParticleScalabilityStateResource {
        guard isEnabled else { return .default }

        let pressureSample = pressure(from: previousStats)
        let nextScale: Float
        if pressureSample.pressure > 0 {
            let reduction = pressureStep * min(1, pressureSample.pressure)
            nextScale = max(minimumScale, previousState.appliedScale * (1 - reduction))
        } else {
            nextScale = min(1, previousState.appliedScale + recoveryStep)
        }
        return ParticleScalabilityStateResource(appliedScale: nextScale,
                                                pressure: pressureSample.pressure,
                                                reason: pressureSample.reason)
    }

    private func pressure(from stats: ParticleFrameStatsResource)
        -> (pressure: Float, reason: ParticleScalabilityPressureReason) {
        if stats.capacityLimitedSpawnCount > 0 {
            return (1, .capacityLimited)
        }
        if stats.spawnBudgetLimitedCount > 0 || stats.gpuDroppedSpawnCount > 0 {
            return (1, .spawnBudget)
        }

        var pressure: Float = 0
        var reason: ParticleScalabilityPressureReason = .none
        let liveParticleCount = max(stats.liveParticleCount, stats.gpuAliveParticleCount)
        if targetLiveParticles > 0, liveParticleCount > targetLiveParticles {
            pressure = max(pressure, Float(liveParticleCount - targetLiveParticles)
                           / Float(targetLiveParticles))
            reason = .liveBudget
        }
        if targetSpawnedParticlesPerFrame > 0,
           stats.spawnedParticleCount > targetSpawnedParticlesPerFrame {
            let spawnPressure = Float(stats.spawnedParticleCount - targetSpawnedParticlesPerFrame)
                / Float(targetSpawnedParticlesPerFrame)
            if spawnPressure > pressure {
                pressure = spawnPressure
                reason = .spawnBudget
            }
        }
        return (pressure, reason)
    }
}

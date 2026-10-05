import EngineKernel
import SIMDCompat

public struct ParticleEmitterFrameStats: Sendable, Equatable {
    public var simulatedDeltaTime: Float
    public var startingLiveParticleCount: Int
    public var liveParticleCount: Int
    public var maxParticleCount: Int
    public var liveParticleLimit: Int
    public var continuousSpawnedCount: Int
    public var burstSpawnedCount: Int
    public var distanceSpawnedCount: Int
    public var subEmitterSpawnedCount: Int
    public var expiredParticleCount: Int
    public var collisionCount: Int
    public var requestedSpawnCount: Int
    public var spawnBudgetLimit: Int
    public var spawnBudgetConsumedCount: Int
    public var capacityLimitedSpawnCount: Int
    public var spawnBudgetLimitedCount: Int

    public init(simulatedDeltaTime: Float = 0,
                startingLiveParticleCount: Int = 0,
                liveParticleCount: Int = 0,
                maxParticleCount: Int = 0,
                liveParticleLimit: Int = 0,
                continuousSpawnedCount: Int = 0,
                burstSpawnedCount: Int = 0,
                distanceSpawnedCount: Int = 0,
                subEmitterSpawnedCount: Int = 0,
                expiredParticleCount: Int = 0,
                collisionCount: Int = 0,
                requestedSpawnCount: Int = 0,
                spawnBudgetLimit: Int = 0,
                spawnBudgetConsumedCount: Int = 0,
                capacityLimitedSpawnCount: Int = 0,
                spawnBudgetLimitedCount: Int = 0) {
        self.simulatedDeltaTime = max(0, simulatedDeltaTime)
        self.startingLiveParticleCount = max(0, startingLiveParticleCount)
        self.liveParticleCount = max(0, liveParticleCount)
        self.maxParticleCount = max(0, maxParticleCount)
        self.liveParticleLimit = max(0, liveParticleLimit)
        self.continuousSpawnedCount = max(0, continuousSpawnedCount)
        self.burstSpawnedCount = max(0, burstSpawnedCount)
        self.distanceSpawnedCount = max(0, distanceSpawnedCount)
        self.subEmitterSpawnedCount = max(0, subEmitterSpawnedCount)
        self.expiredParticleCount = max(0, expiredParticleCount)
        self.collisionCount = max(0, collisionCount)
        self.requestedSpawnCount = max(0, requestedSpawnCount)
        self.spawnBudgetLimit = max(0, spawnBudgetLimit)
        self.spawnBudgetConsumedCount = max(0, spawnBudgetConsumedCount)
        self.capacityLimitedSpawnCount = max(0, capacityLimitedSpawnCount)
        self.spawnBudgetLimitedCount = max(0, spawnBudgetLimitedCount)
    }

    public static let empty = ParticleEmitterFrameStats()

    public var spawnedParticleCount: Int {
        continuousSpawnedCount + burstSpawnedCount + distanceSpawnedCount + subEmitterSpawnedCount
    }

    public var liveParticleBudgetLimit: Int {
        liveParticleLimit > 0 ? liveParticleLimit : maxParticleCount
    }

    public var liveParticleBudgetUtilization: Float {
        guard liveParticleBudgetLimit > 0 else { return 0 }
        return Float(liveParticleCount) / Float(liveParticleBudgetLimit)
    }

    public var droppedSpawnCount: Int {
        capacityLimitedSpawnCount + spawnBudgetLimitedCount
    }

    public var spawnBudgetUtilization: Float {
        guard spawnBudgetLimit > 0 else { return 0 }
        return Float(min(spawnBudgetConsumedCount, spawnBudgetLimit)) / Float(spawnBudgetLimit)
    }

    public var runtimePressureLevel: ParticleRuntimePressureLevel {
        if droppedSpawnCount > 0 || liveParticleBudgetUtilization >= 1 {
            return .critical
        }
        if liveParticleBudgetUtilization >= 0.9 {
            return .warning
        }
        if liveParticleCount > 0 || spawnedParticleCount > 0 {
            return .nominal
        }
        return .idle
    }
}

public struct ParticleFrameStatsResource: Sendable, Equatable {
    public var simulatedDeltaTime: Float
    public var emitterStatsByEntity: [UInt64: ParticleEmitterFrameStats]
    public var emitterCount: Int
    public var activeEmitterCount: Int
    public var liveParticleCount: Int
    public var maxParticleCount: Int
    public var liveParticleLimit: Int
    public var liveParticleBudgetLimit: Int
    public var spawnedParticleCount: Int
    public var continuousSpawnedCount: Int
    public var burstSpawnedCount: Int
    public var distanceSpawnedCount: Int
    public var subEmitterSpawnedCount: Int
    public var expiredParticleCount: Int
    public var collisionCount: Int
    public var requestedSpawnCount: Int
    public var spawnBudgetLimit: Int
    public var spawnBudgetConsumedCount: Int
    public var capacityLimitedSpawnCount: Int
    public var spawnBudgetLimitedCount: Int
    public var gpuAliveParticleCount: Int
    public var gpuExpiredParticleCount: Int
    public var gpuCollisionEventCount: Int
    public var gpuSpawnedParticleCount: Int
    public var gpuDroppedSpawnCount: Int
    public var gpuCompactedParticleCount: Int
    public var runtimePressureLevel: ParticleRuntimePressureLevel

    public init(simulatedDeltaTime: Float = 0,
                emitterStats: [ParticleEmitterFrameStats] = [],
                emitterStatsByEntity: [UInt64: ParticleEmitterFrameStats] = [:],
                gpuAliveParticleCount: Int = 0,
                gpuExpiredParticleCount: Int = 0,
                gpuCollisionEventCount: Int = 0,
                gpuSpawnedParticleCount: Int = 0,
                gpuDroppedSpawnCount: Int = 0,
                gpuCompactedParticleCount: Int = 0) {
        self.simulatedDeltaTime = max(0, simulatedDeltaTime)
        self.emitterStatsByEntity = emitterStatsByEntity
        self.emitterCount = emitterStats.count
        self.activeEmitterCount = emitterStats.filter {
            $0.liveParticleCount > 0 || $0.spawnedParticleCount > 0 || $0.requestedSpawnCount > 0
        }.count
        self.liveParticleCount = emitterStats.reduce(0) { $0 + $1.liveParticleCount }
        self.maxParticleCount = emitterStats.reduce(0) { $0 + $1.maxParticleCount }
        self.liveParticleLimit = emitterStats.reduce(0) { $0 + $1.liveParticleLimit }
        self.liveParticleBudgetLimit = emitterStats.reduce(0) { $0 + $1.liveParticleBudgetLimit }
        self.spawnedParticleCount = emitterStats.reduce(0) { $0 + $1.spawnedParticleCount }
        self.continuousSpawnedCount = emitterStats.reduce(0) { $0 + $1.continuousSpawnedCount }
        self.burstSpawnedCount = emitterStats.reduce(0) { $0 + $1.burstSpawnedCount }
        self.distanceSpawnedCount = emitterStats.reduce(0) { $0 + $1.distanceSpawnedCount }
        self.subEmitterSpawnedCount = emitterStats.reduce(0) { $0 + $1.subEmitterSpawnedCount }
        self.expiredParticleCount = emitterStats.reduce(0) { $0 + $1.expiredParticleCount }
        self.collisionCount = emitterStats.reduce(0) { $0 + $1.collisionCount }
        self.requestedSpawnCount = emitterStats.reduce(0) { $0 + $1.requestedSpawnCount }
        self.spawnBudgetLimit = emitterStats.reduce(0) { $0 + $1.spawnBudgetLimit }
        self.spawnBudgetConsumedCount = emitterStats.reduce(0) { $0 + $1.spawnBudgetConsumedCount }
        self.capacityLimitedSpawnCount = emitterStats.reduce(0) { $0 + $1.capacityLimitedSpawnCount }
        self.spawnBudgetLimitedCount = emitterStats.reduce(0) { $0 + $1.spawnBudgetLimitedCount }
        self.gpuAliveParticleCount = max(0, gpuAliveParticleCount)
        self.gpuExpiredParticleCount = max(0, gpuExpiredParticleCount)
        self.gpuCollisionEventCount = max(0, gpuCollisionEventCount)
        self.gpuSpawnedParticleCount = max(0, gpuSpawnedParticleCount)
        self.gpuDroppedSpawnCount = max(0, gpuDroppedSpawnCount)
        self.gpuCompactedParticleCount = max(0, gpuCompactedParticleCount)
        let emitterPressure = emitterStats.reduce(.idle) {
            dominantParticleRuntimePressureLevel($0, $1.runtimePressureLevel)
        }
        self.runtimePressureLevel = dominantParticleRuntimePressureLevel(
            emitterPressure,
            Self.gpuRuntimePressureLevel(gpuAliveParticleCount: self.gpuAliveParticleCount,
                                         gpuDroppedSpawnCount: self.gpuDroppedSpawnCount,
                                         liveParticleBudgetLimit: self.liveParticleBudgetLimit)
        )
    }

    public static let empty = ParticleFrameStatsResource()

    public func emitterStats(for rawEntityID: UInt64?) -> ParticleEmitterFrameStats? {
        rawEntityID.flatMap { emitterStatsByEntity[$0] }
    }

    public var liveParticleBudgetUtilization: Float {
        guard liveParticleBudgetLimit > 0 else { return 0 }
        return Float(liveParticleCount) / Float(liveParticleBudgetLimit)
    }

    public var droppedSpawnCount: Int {
        capacityLimitedSpawnCount + spawnBudgetLimitedCount + gpuDroppedSpawnCount
    }

    public var spawnBudgetUtilization: Float {
        guard spawnBudgetLimit > 0 else { return 0 }
        return Float(min(spawnBudgetConsumedCount, spawnBudgetLimit)) / Float(spawnBudgetLimit)
    }

    public func mergingGPUReadback(_ report: ParticleSimulationEventApplyReport) -> ParticleFrameStatsResource {
        var stats = self
        stats.gpuAliveParticleCount = report.gpuAliveParticleCount
        stats.gpuExpiredParticleCount = report.gpuExpiredParticleCount
        stats.gpuCollisionEventCount = report.gpuCollisionEventCount
        stats.gpuSpawnedParticleCount = report.gpuSpawnedParticleCount
        stats.gpuDroppedSpawnCount = report.gpuDroppedSpawnCount
        stats.gpuCompactedParticleCount = report.gpuCompactedParticleCount
        stats.runtimePressureLevel = dominantParticleRuntimePressureLevel(
            stats.runtimePressureLevel,
            Self.gpuRuntimePressureLevel(gpuAliveParticleCount: stats.gpuAliveParticleCount,
                                         gpuDroppedSpawnCount: stats.gpuDroppedSpawnCount,
                                         liveParticleBudgetLimit: stats.liveParticleBudgetLimit)
        )
        return stats
    }

    private static func gpuRuntimePressureLevel(gpuAliveParticleCount: Int,
                                                gpuDroppedSpawnCount: Int,
                                                liveParticleBudgetLimit: Int)
        -> ParticleRuntimePressureLevel {
        if gpuDroppedSpawnCount > 0 {
            return .critical
        }
        if liveParticleBudgetLimit > 0, gpuAliveParticleCount >= liveParticleBudgetLimit {
            return .critical
        }
        if liveParticleBudgetLimit > 0,
           Float(gpuAliveParticleCount) / Float(liveParticleBudgetLimit) >= 0.9 {
            return .warning
        }
        if gpuAliveParticleCount > 0 {
            return .nominal
        }
        return .idle
    }

}

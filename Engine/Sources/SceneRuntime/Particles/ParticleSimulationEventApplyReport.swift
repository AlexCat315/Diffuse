import EngineKernel
import SIMDCompat

public struct ParticleSimulationEventApplyReport: Sendable, Equatable {
    public var requestedEmitterCount: Int
    public var appliedEmitterCount: Int
    public var missingEmitterCount: Int
    public var emptyEventEmitterCount: Int
    public var eventCount: Int
    public var appliedEventCount: Int
    public var totalReadbackEventCount: Int
    public var droppedReadbackEventCount: Int
    public var collisionEventCount: Int
    public var deathEventCount: Int
    public var subEmitterSpawnedCount: Int
    public var spawnedParticleCount: Int
    public var gpuAliveParticleCount: Int
    public var gpuExpiredParticleCount: Int
    public var gpuCollisionEventCount: Int
    public var gpuSpawnedParticleCount: Int
    public var gpuDroppedSpawnCount: Int
    public var gpuCompactedParticleCount: Int
    public var requestedSpawnCount: Int
    public var spawnBudgetLimit: Int
    public var spawnBudgetConsumedCount: Int
    public var capacityLimitedSpawnCount: Int
    public var spawnBudgetLimitedCount: Int
    public var emitterStatsByEntity: [UInt64: ParticleEmitterFrameStats]

    public init(requestedEmitterCount: Int = 0,
                appliedEmitterCount: Int = 0,
                missingEmitterCount: Int = 0,
                emptyEventEmitterCount: Int = 0,
                eventCount: Int = 0,
                appliedEventCount: Int = 0,
                totalReadbackEventCount: Int = 0,
                droppedReadbackEventCount: Int = 0,
                collisionEventCount: Int = 0,
                deathEventCount: Int = 0,
                subEmitterSpawnedCount: Int = 0,
                spawnedParticleCount: Int = 0,
                gpuAliveParticleCount: Int = 0,
                gpuExpiredParticleCount: Int = 0,
                gpuCollisionEventCount: Int = 0,
                gpuSpawnedParticleCount: Int = 0,
                gpuDroppedSpawnCount: Int = 0,
                gpuCompactedParticleCount: Int = 0,
                requestedSpawnCount: Int = 0,
                spawnBudgetLimit: Int = 0,
                spawnBudgetConsumedCount: Int = 0,
                capacityLimitedSpawnCount: Int = 0,
                spawnBudgetLimitedCount: Int = 0,
                emitterStatsByEntity: [UInt64: ParticleEmitterFrameStats] = [:]) {
        self.requestedEmitterCount = max(0, requestedEmitterCount)
        self.appliedEmitterCount = max(0, appliedEmitterCount)
        self.missingEmitterCount = max(0, missingEmitterCount)
        self.emptyEventEmitterCount = max(0, emptyEventEmitterCount)
        self.eventCount = max(0, eventCount)
        self.appliedEventCount = max(0, appliedEventCount)
        self.totalReadbackEventCount = max(0, totalReadbackEventCount)
        self.droppedReadbackEventCount = max(0, droppedReadbackEventCount)
        self.collisionEventCount = max(0, collisionEventCount)
        self.deathEventCount = max(0, deathEventCount)
        self.subEmitterSpawnedCount = max(0, subEmitterSpawnedCount)
        self.spawnedParticleCount = max(0, spawnedParticleCount)
        self.gpuAliveParticleCount = max(0, gpuAliveParticleCount)
        self.gpuExpiredParticleCount = max(0, gpuExpiredParticleCount)
        self.gpuCollisionEventCount = max(0, gpuCollisionEventCount)
        self.gpuSpawnedParticleCount = max(0, gpuSpawnedParticleCount)
        self.gpuDroppedSpawnCount = max(0, gpuDroppedSpawnCount)
        self.gpuCompactedParticleCount = max(0, gpuCompactedParticleCount)
        self.requestedSpawnCount = max(0, requestedSpawnCount)
        self.spawnBudgetLimit = max(0, spawnBudgetLimit)
        self.spawnBudgetConsumedCount = max(0, spawnBudgetConsumedCount)
        self.capacityLimitedSpawnCount = max(0, capacityLimitedSpawnCount)
        self.spawnBudgetLimitedCount = max(0, spawnBudgetLimitedCount)
        self.emitterStatsByEntity = emitterStatsByEntity
    }

    public static let empty = ParticleSimulationEventApplyReport()

    public func emitterStats(for rawEntityID: UInt64?) -> ParticleEmitterFrameStats? {
        rawEntityID.flatMap { emitterStatsByEntity[$0] }
    }

    public var droppedSpawnCount: Int {
        capacityLimitedSpawnCount + spawnBudgetLimitedCount + gpuDroppedSpawnCount
    }

    public var spawnBudgetUtilization: Float {
        guard spawnBudgetLimit > 0 else { return 0 }
        return Float(min(spawnBudgetConsumedCount, spawnBudgetLimit)) / Float(spawnBudgetLimit)
    }
}

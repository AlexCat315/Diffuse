import EngineKernel
import SIMDCompat

public extension SceneRuntime {
    /// Advances every `ParticleEmitter` in the scene by `deltaTime` seconds.
    /// Returns the number of emitters stepped.
    @discardableResult
    mutating func advanceParticles(deltaTime: Double,
                                   options: ParticleAdvanceOptions = .default) -> Int {
        let particleEntities = entities(with: ParticleEmitter.self)
        let worldTransforms = Dictionary(uniqueKeysWithValues: particleEntities.map {
            ($0, worldTransform(for: $0)?.matrix ?? matrix_identity_float4x4)
        })
        let policy = resource(ParticleScalabilityPolicyResource.self) ?? .disabled
        let scalabilityState = policy.updatedState(
            previousStats: particleFrameStats,
            previousState: resource(ParticleScalabilityStateResource.self) ?? .default
        )
        setResource(scalabilityState)
        let effectiveOptions = scalabilityState.applying(to: options)
        var particleStats: [ParticleEmitterFrameStats] = []
        var particleStatsByEntity: [UInt64: ParticleEmitterFrameStats] = [:]
        particleStats.reserveCapacity(particleEntities.count)
        particleStatsByEntity.reserveCapacity(particleEntities.count)
        let stepped = updateComponents(ParticleEmitter.self) { entity, emitter in
            emitter.advance(deltaTime: deltaTime,
                            worldTransform: worldTransforms[entity] ?? matrix_identity_float4x4,
                            options: effectiveOptions)
            particleStats.append(emitter.lastFrameStats)
            particleStatsByEntity[entity.rawValue] = emitter.lastFrameStats
        }
        setResource(ParticleFrameStatsResource(simulatedDeltaTime: Float(max(0, deltaTime)),
                                               emitterStats: particleStats,
                                               emitterStatsByEntity: particleStatsByEntity))
        return stepped
    }

    /// Emits particles immediately from one entity's `ParticleEmitter`.
    /// Returns false when the entity has no particle emitter.
    @discardableResult
    mutating func emitParticles(from entity: EntityID, count: Int) -> Bool {
        let transform = worldTransform(for: entity)?.matrix
        return updateComponent(ParticleEmitter.self, for: entity) { emitter in
            emitter.emit(count, worldTransform: transform)
        }
    }

    @discardableResult
    mutating func applyParticleSimulationEvents(
        _ eventsByEntity: [EntityID: [ParticleEvent]]
    ) -> ParticleSimulationEventApplyReport {
        var report = ParticleSimulationEventApplyReport(
            requestedEmitterCount: eventsByEntity.count,
            eventCount: eventsByEntity.values.reduce(0) { $0 + $1.count }
        )
        var emitterStats: [ParticleEmitterFrameStats] = []
        var emitterStatsByEntity: [UInt64: ParticleEmitterFrameStats] = [:]
        emitterStats.reserveCapacity(eventsByEntity.count)
        emitterStatsByEntity.reserveCapacity(eventsByEntity.count)
        for (entity, events) in eventsByEntity {
            guard !events.isEmpty else {
                report.emptyEventEmitterCount += 1
                continue
            }
            var appliedStats: ParticleEmitterFrameStats?
            let updated = updateComponent(ParticleEmitter.self, for: entity) { emitter in
                let stats = emitter.applySimulationEvents(events)
                appliedStats = stats
                emitterStats.append(stats)
                emitterStatsByEntity[entity.rawValue] = stats
            }
            if updated, let appliedStats {
                report.appliedEmitterCount += 1
                report.appliedEventCount += events.count
                report.collisionEventCount += appliedStats.collisionCount
                report.deathEventCount += appliedStats.expiredParticleCount
                report.subEmitterSpawnedCount += appliedStats.subEmitterSpawnedCount
                report.spawnedParticleCount += appliedStats.spawnedParticleCount
                report.requestedSpawnCount += appliedStats.requestedSpawnCount
                report.spawnBudgetLimit += appliedStats.spawnBudgetLimit
                report.spawnBudgetConsumedCount += appliedStats.spawnBudgetConsumedCount
                report.capacityLimitedSpawnCount += appliedStats.capacityLimitedSpawnCount
                report.spawnBudgetLimitedCount += appliedStats.spawnBudgetLimitedCount
            } else {
                report.missingEmitterCount += 1
            }
        }
        if !emitterStats.isEmpty {
            setResource(
                ParticleFrameStatsResource(simulatedDeltaTime: 0,
                                           emitterStats: emitterStats,
                                           emitterStatsByEntity: emitterStatsByEntity)
            )
        }
        report.emitterStatsByEntity = emitterStatsByEntity
        return report
    }
}

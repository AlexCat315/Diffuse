import EngineKernel
import SIMDCompat

extension ParticleEmitter {
    // MARK: - Internals

    struct ParticleSpawnResult {
        var requested: Int
        var spawned: Int
        var capacityLimitedCount: Int = 0
        var spawnBudgetLimitedCount: Int = 0

        var dropped: Int {
            capacityLimitedCount + spawnBudgetLimitedCount
        }

        mutating func include(_ other: ParticleSpawnResult) {
            requested += other.requested
            spawned += other.spawned
            capacityLimitedCount += other.capacityLimitedCount
            spawnBudgetLimitedCount += other.spawnBudgetLimitedCount
        }
    }

    struct ParticleSpawnBudget {
        let limit: Int
        private var remaining: Int?
        private(set) var consumedCount: Int = 0

        init(limit: Int) {
            self.limit = max(0, limit)
            remaining = limit > 0 ? limit : nil
        }

        mutating func grant(_ requested: Int) -> (granted: Int, rejected: Int) {
            let requested = max(0, requested)
            guard requested > 0 else { return (0, 0) }
            guard let current = remaining else {
                consumedCount += requested
                return (requested, 0)
            }
            let granted = min(requested, max(0, current))
            remaining = max(0, current - granted)
            consumedCount += granted
            return (granted, requested - granted)
        }
    }

    private struct ParticleSpawnSample {
        var offset: SIMD3<Float>
        var velocityJitter: SIMD3<Float>
        var lifetime: Float
        var sizeScale: Float
        var rotation: Float
        var angularVelocity: Float
        var textureFrameSeed: UInt16
    }

    @discardableResult
    mutating func spawn(_ count: Int,
                                worldTransform: simd_float4x4? = nil,
                                worldOriginOverride: SIMD3<Float>? = nil,
                                inheritedWorldVelocity: SIMD3<Float> = .zero,
                                maxLiveParticles: Int? = nil,
                                recordSpawned: Bool = true,
                                budget: inout ParticleSpawnBudget) -> ParticleSpawnResult {
        let requested = max(0, count)
        guard requested > 0, settings.emission.maxParticles > 0 else {
            return ParticleSpawnResult(requested: requested,
                                       spawned: 0,
                                       capacityLimitedCount: requested)
        }
        let budgetGrant = budget.grant(requested)
        let liveLimit = min(settings.emission.maxParticles, max(0, maxLiveParticles ?? settings.emission.maxParticles))
        let room = liveLimit - runtime.particles.count
        let n = min(budgetGrant.granted, max(0, room))
        for _ in 0..<n {
            let sample = makeSpawnSample()
            let localPosition = settings.shape.originOffset + sample.offset
            let localVelocity = settings.velocity.startVelocity + sample.velocityJitter
            let spawnTransform = worldTransform ?? matrix_identity_float4x4
            let inheritedVelocity = inheritedSpawnVelocity(inheritedWorldVelocity,
                                                           spawnTransform: spawnTransform)
            let position: SIMD3<Float>
            let velocity: SIMD3<Float>
            switch settings.gpuSimulation.simulationSpace {
            case .local:
                position = localPosition
                velocity = localVelocity + inheritedVelocity
            case .world:
                if let worldOriginOverride {
                    position = worldOriginOverride + Self.transformDirection(sample.offset, by: spawnTransform)
                } else {
                    position = Self.transformPoint(localPosition, by: spawnTransform)
                }
                velocity = Self.transformDirection(localVelocity, by: spawnTransform) + inheritedVelocity
            }
            var p = Particle(position: position,
                             velocity: velocity,
                             lifetime: sample.lifetime,
                             sizeScale: sample.sizeScale,
                             rotation: sample.rotation,
                             angularVelocity: sample.angularVelocity,
                             generation: 0,
                             textureFrameSeed: sample.textureFrameSeed)
            refreshAppearance(&p)
            runtime.particles.append(p)
            if recordSpawned {
                runtime.lastFrameSpawnedParticles.append(p)
            }
        }
        return ParticleSpawnResult(requested: requested,
                                   spawned: n,
                                   capacityLimitedCount: budgetGrant.granted - n,
                                   spawnBudgetLimitedCount: budgetGrant.rejected)
    }

    @discardableResult
    mutating func spawn(_ count: Int,
                                worldTransform: simd_float4x4? = nil,
                                worldOriginOverride: SIMD3<Float>? = nil,
                                inheritedWorldVelocity: SIMD3<Float> = .zero,
                                maxLiveParticles: Int? = nil,
                                recordSpawned: Bool = true) -> ParticleSpawnResult {
        var budget = ParticleSpawnBudget(limit: 0)
        return spawn(count,
                     worldTransform: worldTransform,
                     worldOriginOverride: worldOriginOverride,
                     inheritedWorldVelocity: inheritedWorldVelocity,
                     maxLiveParticles: maxLiveParticles,
                     recordSpawned: recordSpawned,
                     budget: &budget)
    }

    private mutating func makeSpawnSample() -> ParticleSpawnSample {
        let offset = spawnOffset()
        let jitter = SIMD3<Float>(nextSigned() * settings.velocity.velocityRandomness.x,
                                  nextSigned() * settings.velocity.velocityRandomness.y,
                                  nextSigned() * settings.velocity.velocityRandomness.z)
        return ParticleSpawnSample(
            offset: offset,
            velocityJitter: jitter,
            lifetime: max(0.0001, settings.appearance.lifetime + nextSigned() * settings.appearance.lifetimeRandomness),
            sizeScale: max(0, 1 + nextSigned() * settings.appearance.sizeRandomness),
            rotation: settings.appearance.startRotation + nextSigned() * settings.appearance.rotationRandomness,
            angularVelocity: settings.appearance.angularVelocity + nextSigned() * settings.appearance.angularVelocityRandomness,
            textureFrameSeed: textureFrameSeedSnapshot()
        )
    }

    mutating func spawnSubEmitterParticles(trigger: ParticleSubEmitterTrigger,
                                                   source: Particle,
                                                   survivorsCount: Int,
                                                   pending: inout [Particle],
                                                   budget: inout ParticleSpawnBudget) -> ParticleSpawnResult {
        guard settings.emission.maxParticles > 0 else {
            return ParticleSpawnResult(requested: 0, spawned: 0)
        }
        var result = ParticleSpawnResult(requested: 0, spawned: 0)
        if let legacy = legacySubEmitterRule, legacy.trigger == trigger {
            result.include(
                spawnSubEmitterParticles(legacy,
                                         appearanceIndex: 1,
                                         source: source,
                                         survivorsCount: survivorsCount,
                                         pending: &pending,
                                         budget: &budget)
            )
        }
        for (index, rule) in settings.subEmitters.rules.enumerated() where rule.trigger == trigger {
            result.include(
                spawnSubEmitterParticles(rule,
                                         appearanceIndex: UInt16(clamping: index + 2),
                                         source: source,
                                         survivorsCount: survivorsCount,
                                         pending: &pending,
                                         budget: &budget)
            )
        }
        return result
    }

    mutating func spawnSubEmitterParticles(_ rule: ParticleSubEmitter,
                                                   appearanceIndex: UInt16,
                                                   source: Particle,
                                                   survivorsCount: Int,
                                                   pending: inout [Particle],
                                                   budget: inout ParticleSpawnBudget) -> ParticleSpawnResult {
        guard rule.isActive,
              source.generation < UInt8(clamping: rule.maxDepth)
        else { return ParticleSpawnResult(requested: 0, spawned: 0) }
        if rule.probability < 1, nextUnit() > rule.probability {
            return ParticleSpawnResult(requested: 0, spawned: 0)
        }

        let room = settings.emission.maxParticles - survivorsCount - pending.count
        guard room > 0 else {
            return ParticleSpawnResult(requested: rule.burstCount,
                                       spawned: 0,
                                       capacityLimitedCount: rule.burstCount)
        }
        let budgetGrant = budget.grant(rule.burstCount)
        let count = min(budgetGrant.granted, room)
        let childGeneration = source.generation == UInt8.max ? UInt8.max : source.generation + 1
        for _ in 0..<count {
            let jitter = SIMD3<Float>(
                nextSigned() * rule.velocityRandomness.x,
                nextSigned() * rule.velocityRandomness.y,
                nextSigned() * rule.velocityRandomness.z
            )
            var child = Particle(position: source.position,
                                 velocity: rule.startVelocity + jitter
                                    + source.velocity * rule.inheritVelocity,
                                 lifetime: rule.lifetime,
                                 sizeScale: 1,
                                 rotation: settings.appearance.startRotation + nextSigned() * settings.appearance.rotationRandomness,
                                 angularVelocity: settings.appearance.angularVelocity + nextSigned() * settings.appearance.angularVelocityRandomness,
                                 generation: childGeneration,
                                 appearanceIndex: appearanceIndex,
                                 textureFrameSeed: textureFrameSeedSnapshot())
            refreshAppearance(&child)
            pending.append(child)
        }
        return ParticleSpawnResult(requested: rule.burstCount,
                                   spawned: count,
                                   capacityLimitedCount: budgetGrant.granted - count,
                                   spawnBudgetLimitedCount: budgetGrant.rejected)
    }

    mutating func appendEventParticles(_ eventParticles: [Particle]) -> ParticleSpawnResult {
        guard !eventParticles.isEmpty else {
            return ParticleSpawnResult(requested: 0, spawned: 0)
        }
        let room = settings.emission.maxParticles - runtime.particles.count
        guard room > 0 else {
            return ParticleSpawnResult(requested: eventParticles.count,
                                       spawned: 0,
                                       capacityLimitedCount: eventParticles.count)
        }
        let toAppend = min(eventParticles.count, room)
        runtime.particles.append(contentsOf: eventParticles.prefix(toAppend))
        runtime.lastFrameSpawnedParticles.append(contentsOf: eventParticles.prefix(toAppend))
        return ParticleSpawnResult(requested: eventParticles.count,
                                   spawned: toAppend,
                                   capacityLimitedCount: eventParticles.count - toAppend)
    }

    mutating func spawnDistanceEmission(from previous: SIMD3<Float>?,
                                                to current: SIMD3<Float>,
                                                worldTransform: simd_float4x4?,
                                                inheritedWorldVelocity: SIMD3<Float>,
                                                rateMultiplier: Float,
                                                maxLiveParticles: Int? = nil,
                                                budget: inout ParticleSpawnBudget) -> ParticleSpawnResult {
        defer { runtime.previousEmitterPosition = current }
        guard settings.emission.distanceEmissionRate > 0,
              rateMultiplier > 0,
              let previous else {
            return ParticleSpawnResult(requested: 0, spawned: 0)
        }
        let delta = current - previous
        let distance = simd_length(delta)
        guard distance > 0.0001 else {
            return ParticleSpawnResult(requested: 0, spawned: 0)
        }

        runtime.distanceEmissionAccumulator += distance * settings.emission.distanceEmissionRate * rateMultiplier
        let toSpawn = Int(runtime.distanceEmissionAccumulator)
        guard toSpawn > 0 else {
            return ParticleSpawnResult(requested: 0, spawned: 0)
        }
        runtime.distanceEmissionAccumulator -= Float(toSpawn)

        switch settings.gpuSimulation.simulationSpace {
        case .local:
            return spawn(toSpawn,
                         worldTransform: worldTransform,
                         inheritedWorldVelocity: inheritedWorldVelocity,
                         maxLiveParticles: maxLiveParticles,
                         budget: &budget)
        case .world:
            let budgetGrant = budget.grant(toSpawn)
            let liveLimit = min(settings.emission.maxParticles, max(0, maxLiveParticles ?? settings.emission.maxParticles))
            let accepted = min(budgetGrant.granted, max(0, liveLimit - runtime.particles.count))
            var result = ParticleSpawnResult(
                requested: toSpawn,
                spawned: 0,
                capacityLimitedCount: budgetGrant.granted - accepted,
                spawnBudgetLimitedCount: budgetGrant.rejected
            )
            var unrestrictedBudget = ParticleSpawnBudget(limit: 0)
            for index in 0..<accepted {
                let t = (Float(index) + 0.5) / Float(max(1, accepted))
                let worldOrigin = previous + delta * t
                let spawnResult = spawn(1,
                                        worldTransform: worldTransform,
                                        worldOriginOverride: worldOrigin,
                                        inheritedWorldVelocity: inheritedWorldVelocity,
                                        maxLiveParticles: maxLiveParticles,
                                        budget: &unrestrictedBudget)
                result.spawned += spawnResult.spawned
                result.capacityLimitedCount += spawnResult.capacityLimitedCount
                result.spawnBudgetLimitedCount += spawnResult.spawnBudgetLimitedCount
            }
            return result
        }
    }

    func inheritedEmitterVelocity(from previous: SIMD3<Float>?,
                                          to current: SIMD3<Float>,
                                          deltaTime: Float) -> SIMD3<Float> {
        guard settings.velocity.velocityInheritance > 0,
              let previous,
              deltaTime > 0.0001
        else { return .zero }
        return (current - previous) / deltaTime
    }

    private func inheritedSpawnVelocity(_ worldVelocity: SIMD3<Float>,
                                        spawnTransform: simd_float4x4) -> SIMD3<Float> {
        guard settings.velocity.velocityInheritance > 0 else { return .zero }
        switch settings.gpuSimulation.simulationSpace {
        case .local:
            return Self.transformDirection(worldVelocity, by: simd_inverse(spawnTransform)) * settings.velocity.velocityInheritance
        case .world:
            return worldVelocity * settings.velocity.velocityInheritance
        }
    }

    func distanceEmitterPosition(worldTransform: simd_float4x4?) -> SIMD3<Float> {
        Self.transformPoint(settings.shape.originOffset, by: worldTransform ?? matrix_identity_float4x4)
    }

    private static func transformPoint(_ point: SIMD3<Float>, by matrix: simd_float4x4) -> SIMD3<Float> {
        let transformed = matrix * SIMD4<Float>(point, 1)
        if abs(transformed.w) > 0.0001 {
            return SIMD3<Float>(
                transformed.x / transformed.w,
                transformed.y / transformed.w,
                transformed.z / transformed.w
            )
        }
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    private static func transformDirection(_ direction: SIMD3<Float>, by matrix: simd_float4x4) -> SIMD3<Float> {
        let transformed = matrix * SIMD4<Float>(direction, 0)
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    var legacySubEmitterRule: ParticleSubEmitter? {
        guard settings.subEmitters.legacyTrigger != .none,
              settings.subEmitters.legacyBurstCount > 0
        else { return nil }
        return ParticleSubEmitter(trigger: settings.subEmitters.legacyTrigger,
                                  burstCount: settings.subEmitters.legacyBurstCount,
                                  probability: settings.subEmitters.legacyProbability,
                                  maxDepth: settings.subEmitters.legacyMaxDepth,
                                  inheritVelocity: settings.subEmitters.legacyInheritVelocity,
                                  lifetime: settings.subEmitters.legacyLifetime,
                                  startVelocity: settings.subEmitters.legacyStartVelocity,
                                  velocityRandomness: settings.subEmitters.legacyVelocityRandomness,
                                  startSize: settings.subEmitters.legacyStartSize,
                                  endSize: settings.subEmitters.legacyEndSize,
                                  startColor: settings.subEmitters.legacyStartColor,
                                  endColor: settings.subEmitters.legacyEndColor)
    }
}

import EngineKernel
import SIMDCompat

extension ParticleEmitter {
    /// Number of currently-alive particles.
    public var aliveCount: Int { runtime.particles.count }

    /// True while this emitter can still produce new particles from its authored
    /// emission controls. Non-looping emitters become inactive once `duration`
    /// is exhausted, even if `isEmitting` remains enabled for authoring.
    public var isEmissionActive: Bool {
        guard isEmitting else { return false }
        guard duration > 0 else { return true }
        return looping || runtime.emitterAge < duration
    }

    public mutating func reseed(_ newSeed: UInt64) {
        seed = newSeed
        runtime.rngState = newSeed
    }

    public var gpuSimulationPlan: ParticleGPUSimulationPlan {
        ParticleGPUSimulationPlan(emitter: self)
    }

    /// Advances the simulation by `deltaTime` seconds: integrates existing particles, culls
    /// expired ones, then spawns from the continuous emission rate and scheduled bursts
    /// (capped at `maxParticles`).
    public mutating func advance(deltaTime: Double,
                                 worldTransform: simd_float4x4? = nil,
                                 options: ParticleAdvanceOptions = .default) {
        guard deltaTime > 0 else { return }
        runPrewarmIfNeeded(worldTransform: worldTransform, options: options)
        let scaledDeltaTime = Float(deltaTime) * max(0, simulationSpeed)
        guard scaledDeltaTime > 0 else {
            runtime.lastFrameSpawnedParticles.removeAll(keepingCapacity: true)
            runtime.lastFrameEvents.removeAll(keepingCapacity: true)
            runtime.previousEmitterPosition = distanceEmitterPosition(worldTransform: worldTransform)
            runtime.lastFrameStats = ParticleEmitterFrameStats(
                simulatedDeltaTime: 0,
                startingLiveParticleCount: runtime.particles.count,
                liveParticleCount: runtime.particles.count,
                maxParticleCount: maxParticles,
                liveParticleLimit: options.liveParticleLimit(configuredMaxParticles: maxParticles)
            )
            return
        }
        advanceStep(deltaTime: scaledDeltaTime, worldTransform: worldTransform, options: options)
    }

    private mutating func advanceStep(deltaTime dt: Float,
                                      worldTransform: simd_float4x4? = nil,
                                      options: ParticleAdvanceOptions = .default) {
        guard dt > 0 else { return }
        runtime.lastFrameSpawnedParticles.removeAll(keepingCapacity: true)
        runtime.lastFrameEvents.removeAll(keepingCapacity: true)
        let liveParticleLimit = options.liveParticleLimit(configuredMaxParticles: maxParticles)
        var frameStats = ParticleEmitterFrameStats(
            simulatedDeltaTime: dt,
            startingLiveParticleCount: runtime.particles.count,
            liveParticleCount: runtime.particles.count,
            maxParticleCount: maxParticles,
            liveParticleLimit: liveParticleLimit,
            spawnBudgetLimit: maxSpawnedParticlesPerFrame
        )
        let currentEmitterPosition = distanceEmitterPosition(worldTransform: worldTransform)
        let inheritedWorldVelocity = inheritedEmitterVelocity(
            from: runtime.previousEmitterPosition,
            to: currentEmitterPosition,
            deltaTime: dt
        )
        let collisionContext = simulationSpace == .local
            ? makeCollisionContext(worldTransform: worldTransform)
            : nil
        let defersEventSubEmittersToExternalSimulation = hasEventSubEmitterRules
            && gpuSimulationPlan.usesGPU
        var spawnBudget = ParticleSpawnBudget(limit: maxSpawnedParticlesPerFrame)

        var survivors: [Particle] = []
        var eventParticles: [Particle] = []
        var eventSubEmitterSpawnResult = ParticleSpawnResult(requested: 0, spawned: 0)
        survivors.reserveCapacity(runtime.particles.count)
        for var p in runtime.particles {
            p.velocity += gravity * dt
            p.velocity += noiseForce(position: p.position, age: p.age) * dt
            p.velocity += forceAcceleration(position: p.position) * dt
            p.velocity += vectorFieldAcceleration(position: p.position, age: p.age) * dt
            p.position += p.velocity * dt
            p.rotation += p.angularVelocity * dt
            let collided = applyCollision(to: &p, context: collisionContext)
            if collided {
                frameStats.collisionCount += 1
                if !defersEventSubEmittersToExternalSimulation {
                    recordEvent(trigger: .collision, source: p)
                    eventSubEmitterSpawnResult.include(
                        spawnSubEmitterParticles(trigger: .collision,
                                                 source: p,
                                                 survivorsCount: survivors.count,
                                                 pending: &eventParticles,
                                                 budget: &spawnBudget)
                    )
                }
            }
            p.age += dt
            if p.age < p.lifetime {
                refreshAppearance(&p)
                survivors.append(p)
            } else {
                frameStats.expiredParticleCount += 1
                if !defersEventSubEmittersToExternalSimulation {
                    recordEvent(trigger: .death, source: p)
                    eventSubEmitterSpawnResult.include(
                        spawnSubEmitterParticles(trigger: .death,
                                                 source: p,
                                                 survivorsCount: survivors.count,
                                                 pending: &eventParticles,
                                                 budget: &spawnBudget)
                    )
                }
            }
        }
        runtime.particles = survivors
        let eventSpawnResult = appendEventParticles(eventParticles)
        frameStats.requestedSpawnCount += eventSubEmitterSpawnResult.requested
        frameStats.subEmitterSpawnedCount += eventSpawnResult.spawned
        frameStats.capacityLimitedSpawnCount += eventSubEmitterSpawnResult.capacityLimitedCount
            + eventSpawnResult.capacityLimitedCount
        frameStats.spawnBudgetLimitedCount += eventSubEmitterSpawnResult.spawnBudgetLimitedCount
            + eventSpawnResult.spawnBudgetLimitedCount

        guard isEmitting else {
            runtime.previousEmitterPosition = currentEmitterPosition
            frameStats.liveParticleCount = runtime.particles.count
            frameStats.spawnBudgetConsumedCount = spawnBudget.consumedCount
            runtime.lastFrameStats = frameStats
            return
        }
        let emissionStep = activeEmissionStep(dt)
        guard emissionStep.delta > 0 else {
            runtime.previousEmitterPosition = currentEmitterPosition
            frameStats.liveParticleCount = runtime.particles.count
            frameStats.spawnBudgetConsumedCount = spawnBudget.consumedCount
            runtime.lastFrameStats = frameStats
            return
        }
        let emissionRateMultiplier = emissionStep.averageMultiplier(for: emissionRateCurve)
        let scaledEmissionRateMultiplier = emissionRateMultiplier * options.emissionScale
        if emissionRate > 0, scaledEmissionRateMultiplier > 0 {
            runtime.emissionAccumulator += emissionRate * scaledEmissionRateMultiplier * emissionStep.delta
            let toSpawn = Int(runtime.emissionAccumulator)
            if toSpawn > 0 {
                runtime.emissionAccumulator -= Float(toSpawn)
                let spawnResult = spawn(toSpawn,
                                        worldTransform: worldTransform,
                                        inheritedWorldVelocity: inheritedWorldVelocity,
                                        maxLiveParticles: liveParticleLimit,
                                        budget: &spawnBudget)
                frameStats.requestedSpawnCount += spawnResult.requested
                frameStats.continuousSpawnedCount += spawnResult.spawned
                frameStats.capacityLimitedSpawnCount += spawnResult.capacityLimitedCount
                frameStats.spawnBudgetLimitedCount += spawnResult.spawnBudgetLimitedCount
            }
        }
        if burstCount > 0, burstInterval > 0 {
            runtime.burstAccumulator += emissionStep.delta
            let bursts = Int(runtime.burstAccumulator / burstInterval)
            if bursts > 0 {
                runtime.burstAccumulator -= Float(bursts) * burstInterval
                runtime.burstSpawnAccumulator += Float(bursts * burstCount) * options.burstScale
                let toSpawn = Int(runtime.burstSpawnAccumulator)
                if toSpawn > 0 {
                    runtime.burstSpawnAccumulator -= Float(toSpawn)
                    let spawnResult = spawn(toSpawn,
                                            worldTransform: worldTransform,
                                            inheritedWorldVelocity: inheritedWorldVelocity,
                                            maxLiveParticles: liveParticleLimit,
                                            budget: &spawnBudget)
                    frameStats.requestedSpawnCount += spawnResult.requested
                    frameStats.burstSpawnedCount += spawnResult.spawned
                    frameStats.capacityLimitedSpawnCount += spawnResult.capacityLimitedCount
                    frameStats.spawnBudgetLimitedCount += spawnResult.spawnBudgetLimitedCount
                }
            }
        }
        let distanceRateMultiplier = emissionStep.averageMultiplier(for: distanceEmissionRateCurve)
        let distanceSpawnResult = spawnDistanceEmission(
            from: runtime.previousEmitterPosition,
            to: currentEmitterPosition,
            worldTransform: worldTransform,
            inheritedWorldVelocity: inheritedWorldVelocity,
            rateMultiplier: distanceRateMultiplier * options.distanceEmissionScale,
            maxLiveParticles: liveParticleLimit,
            budget: &spawnBudget
        )
        frameStats.requestedSpawnCount += distanceSpawnResult.requested
        frameStats.distanceSpawnedCount += distanceSpawnResult.spawned
        frameStats.capacityLimitedSpawnCount += distanceSpawnResult.capacityLimitedCount
        frameStats.spawnBudgetLimitedCount += distanceSpawnResult.spawnBudgetLimitedCount
        frameStats.liveParticleCount = runtime.particles.count
        frameStats.spawnBudgetConsumedCount = spawnBudget.consumedCount
        runtime.lastFrameStats = frameStats
    }

    /// Spawns `count` particles immediately (a burst), independent of the emission rate.
    /// Honors the `maxParticles` cap.
    public mutating func emit(_ count: Int, worldTransform: simd_float4x4? = nil) {
        spawn(count, worldTransform: worldTransform, recordSpawned: false)
    }

    /// Removes all live particles and resets emission timing.
    public mutating func clear() {
        runtime.clear()
    }

    /// Applies collision/death events produced by an external simulation backend and spawns
    /// matching sub-emitter particles through the same rules as CPU simulation.
    @discardableResult
    public mutating func applySimulationEvents(_ events: [ParticleEvent]) -> ParticleEmitterFrameStats {
        runtime.lastFrameSpawnedParticles.removeAll(keepingCapacity: true)
        runtime.lastFrameEvents.removeAll(keepingCapacity: true)
        var frameStats = ParticleEmitterFrameStats(
            startingLiveParticleCount: runtime.particles.count,
            liveParticleCount: runtime.particles.count,
            maxParticleCount: maxParticles,
            liveParticleLimit: maxParticles,
            spawnBudgetLimit: maxSpawnedParticlesPerFrame
        )
        guard !events.isEmpty else {
            runtime.lastFrameStats = frameStats
            return frameStats
        }

        var eventParticles: [Particle] = []
        var eventSubEmitterSpawnResult = ParticleSpawnResult(requested: 0, spawned: 0)
        var spawnBudget = ParticleSpawnBudget(limit: maxSpawnedParticlesPerFrame)
        eventParticles.reserveCapacity(events.count)
        for event in events where event.trigger != .none {
            let source = sourceParticle(from: event)
            switch event.trigger {
            case .collision:
                frameStats.collisionCount += 1
            case .death:
                frameStats.expiredParticleCount += 1
            case .none:
                break
            }
            recordEvent(trigger: event.trigger, source: source)
            eventSubEmitterSpawnResult.include(
                spawnSubEmitterParticles(trigger: event.trigger,
                                         source: source,
                                         survivorsCount: runtime.particles.count,
                                         pending: &eventParticles,
                                         budget: &spawnBudget)
            )
        }

        let eventSpawnResult = appendEventParticles(eventParticles)
        frameStats.requestedSpawnCount += eventSubEmitterSpawnResult.requested
        frameStats.subEmitterSpawnedCount += eventSpawnResult.spawned
        frameStats.capacityLimitedSpawnCount += eventSubEmitterSpawnResult.capacityLimitedCount
            + eventSpawnResult.capacityLimitedCount
        frameStats.spawnBudgetLimitedCount += eventSubEmitterSpawnResult.spawnBudgetLimitedCount
            + eventSpawnResult.spawnBudgetLimitedCount
        frameStats.liveParticleCount = runtime.particles.count
        frameStats.spawnBudgetConsumedCount = spawnBudget.consumedCount
        runtime.lastFrameStats = frameStats
        return frameStats
    }

    private mutating func recordEvent(trigger: ParticleSubEmitterTrigger,
                                      source: Particle) {
        guard trigger != .none else { return }
        runtime.lastFrameEvents.append(ParticleEvent(trigger: trigger, source: source))
    }

    private func sourceParticle(from event: ParticleEvent) -> Particle {
        Particle(position: event.position,
                 velocity: event.velocity,
                 age: event.age,
                 lifetime: event.lifetime,
                 generation: event.generation,
                 appearanceIndex: event.appearanceIndex)
    }

    private mutating func runPrewarmIfNeeded(worldTransform: simd_float4x4?,
                                             options: ParticleAdvanceOptions) {
        guard !runtime.hasPrewarmed,
              isEmitting,
              prewarmTime > 0,
              maxParticles > 0
        else { return }

        runtime.hasPrewarmed = true
        runtime.previousEmitterPosition = distanceEmitterPosition(worldTransform: worldTransform)
        var remaining = prewarmTime
        let step = min(max(1.0 / 240.0, prewarmStep), prewarmTime)
        while remaining > 0.0001 {
            let dt = min(step, remaining)
            advanceStep(deltaTime: dt, worldTransform: worldTransform, options: options)
            remaining -= dt
        }
        runtime.previousEmitterPosition = distanceEmitterPosition(worldTransform: worldTransform)
    }

    private struct ActiveEmissionStep {
        var delta: Float
        var normalizedAge: Float
        var startAge: Float
        var duration: Float
        var looping: Bool

        func averageMultiplier(for curve: ParticleCurve) -> Float {
            guard duration > 0, delta > 0 else {
                return max(0, curve.evaluate(at: normalizedAge))
            }
            let samples = Self.averageCurveSampleCount(delta: delta, duration: duration)
            guard samples > 1 else {
                return max(0, curve.evaluate(at: normalizedAge))
            }

            var total: Float = 0
            for index in 0..<samples {
                let t = (Float(index) + 0.5) / Float(samples)
                var age = startAge + delta * t
                if looping {
                    age = age.truncatingRemainder(dividingBy: duration)
                    if age < 0 { age += duration }
                } else {
                    age = min(max(0, age), duration)
                }
                total += max(0, curve.evaluate(at: simd_clamp(age / duration, 0, 1)))
            }
            return total / Float(samples)
        }

        private static func averageCurveSampleCount(delta: Float, duration: Float) -> Int {
            guard delta > 0, duration > 0 else { return 1 }
            let samplesPerCycle: Float = 8
            let rawSamples = Int(ceil((delta / duration) * samplesPerCycle))
            return min(32, max(1, rawSamples))
        }
    }

    private mutating func activeEmissionStep(_ dt: Float) -> ActiveEmissionStep {
        guard duration > 0 else {
            return ActiveEmissionStep(delta: dt,
                                      normalizedAge: 1,
                                      startAge: 0,
                                      duration: 0,
                                      looping: false)
        }
        let startAge = runtime.emitterAge
        if looping {
            runtime.emitterAge = (runtime.emitterAge + dt).truncatingRemainder(dividingBy: duration)
            let sampleAge = (startAge + dt * 0.5).truncatingRemainder(dividingBy: duration)
            return ActiveEmissionStep(delta: dt,
                                      normalizedAge: simd_clamp(sampleAge / duration, 0, 1),
                                      startAge: startAge,
                                      duration: duration,
                                      looping: true)
        }

        let remaining = max(0, duration - runtime.emitterAge)
        let activeDelta = min(dt, remaining)
        runtime.emitterAge += dt
        let sampleAge = startAge + activeDelta * 0.5
        return ActiveEmissionStep(delta: activeDelta,
                                  normalizedAge: simd_clamp(sampleAge / duration, 0, 1),
                                  startAge: startAge,
                                  duration: duration,
                                  looping: false)
    }

    fileprivate var hasEventSubEmitterRules: Bool {
        legacySubEmitterRule != nil || subEmitters.contains(where: \.isActive)
    }
}

import EngineKernel
import SIMDCompat

extension ParticleEmitter {
    public func effectiveRenderBoundsRadius() -> Float {
        switch settings.renderer.renderBoundsMode {
        case .disabled:
            return 0
        case .manual:
            return max(0, settings.renderer.renderBoundsRadius)
        case .automatic:
            return estimatedRenderBoundsRadius()
        }
    }

    public func renderLODScale(cameraDistance: Float) -> Float {
        guard settings.renderer.renderLODEndDistance > settings.renderer.renderLODStartDistance else {
            return 1
        }
        let t = simd_clamp((max(0, cameraDistance) - settings.renderer.renderLODStartDistance)
                           / (settings.renderer.renderLODEndDistance - settings.renderer.renderLODStartDistance), 0, 1)
        return 1 + (settings.renderer.renderLODMinParticleScale - 1) * t
    }

    public func effectiveMaxRenderedParticles(cameraDistance: Float, liveParticleCount: Int) -> Int {
        let liveCount = max(0, liveParticleCount)
        guard liveCount > 0 else { return 0 }
        let baseLimit = settings.emission.maxRenderedParticles > 0 ? min(settings.emission.maxRenderedParticles, liveCount) : liveCount
        let scale = renderLODScale(cameraDistance: cameraDistance)
        guard scale > 0 else { return 0 }
        return min(baseLimit, max(1, Int(ceil(Float(baseLimit) * scale))))
    }

    public func estimatedRenderBoundsRadius() -> Float {
        let primaryLifetime = max(0.0001, settings.appearance.lifetime + settings.appearance.lifetimeRandomness)
        let spawnExtent = estimatedSpawnExtent()
        let primaryVelocity = estimatedVelocityMagnitude(startVelocity: settings.velocity.startVelocity,
                                                         randomness: settings.velocity.velocityRandomness)
        let acceleration = estimatedAccelerationMagnitude()
        let primaryTravel = estimatedTravelDistance(lifetime: primaryLifetime,
                                                    velocityMagnitude: primaryVelocity,
                                                    accelerationMagnitude: acceleration)
        let childTravel = estimatedSubEmitterExpansion(accelerationMagnitude: acceleration)
        let billboardRadius = estimatedBillboardRadius(velocityMagnitude: max(primaryVelocity, childTravel.velocity))
        let forceExtent: Float
        if settings.forces.forceMode != .none, settings.forces.forceRadius > 0 {
            forceExtent = simd_length(settings.forces.forceCenter) + settings.forces.forceRadius
        } else {
            forceExtent = 0
        }
        let radius = spawnExtent + primaryTravel + childTravel.distance + billboardRadius + forceExtent
        return radius.isFinite ? max(0, radius) : max(0, settings.renderer.renderBoundsRadius)
    }

    private func estimatedSpawnExtent() -> Float {
        switch settings.shape.emissionShape {
        case .sphere:
            return settings.shape.spawnRadius
        case .box:
            return simd_length(settings.shape.boxHalfExtents)
        case .cone:
            return sqrt(settings.shape.coneRadius * settings.shape.coneRadius + settings.shape.coneHeight * settings.shape.coneHeight)
        }
    }

    private func estimatedVelocityMagnitude(startVelocity: SIMD3<Float>,
                                            randomness: SIMD3<Float>) -> Float {
        simd_length(startVelocity) + simd_length(randomness)
    }

    private func estimatedAccelerationMagnitude() -> Float {
        simd_length(settings.forces.gravity) + settings.forces.noiseStrength + abs(settings.forces.forceStrength) + abs(settings.forces.vectorFieldStrength)
    }

    private func estimatedTravelDistance(lifetime: Float,
                                         velocityMagnitude: Float,
                                         accelerationMagnitude: Float) -> Float {
        velocityMagnitude * lifetime + 0.5 * accelerationMagnitude * lifetime * lifetime
    }

    private func estimatedSubEmitterExpansion(
        accelerationMagnitude: Float
    ) -> (distance: Float, velocity: Float) {
        var maxDistance: Float = 0
        var maxVelocity: Float = 0
        if let legacySubEmitterRule {
            accumulateSubEmitterExpansion(rule: legacySubEmitterRule,
                                          accelerationMagnitude: accelerationMagnitude,
                                          maxDistance: &maxDistance,
                                          maxVelocity: &maxVelocity)
        }
        for rule in settings.subEmitters.rules {
            accumulateSubEmitterExpansion(rule: rule,
                                          accelerationMagnitude: accelerationMagnitude,
                                          maxDistance: &maxDistance,
                                          maxVelocity: &maxVelocity)
        }
        return (maxDistance, maxVelocity)
    }

    private func estimatedBillboardRadius(velocityMagnitude: Float) -> Float {
        var size = estimatedMaximumParticleSize(startSize: settings.appearance.startSize, endSize: settings.appearance.endSize)
        size = max(size, estimatedMaximumParticleSize(startSize: settings.subEmitters.legacyStartSize,
                                                      endSize: settings.subEmitters.legacyEndSize))
        for rule in settings.subEmitters.rules {
            size = max(size, estimatedMaximumParticleSize(startSize: rule.startSize,
                                                          endSize: rule.endSize))
        }
        let sizeScale = max(0, 1 + settings.appearance.sizeRandomness)
        let stretch = settings.renderer.renderAlignment == .velocity
            ? min(settings.renderer.velocityStretchMax, max(1, 1 + velocityMagnitude * settings.renderer.velocityStretchScale))
            : 1
        let billboardRadius = max(0, size) * sizeScale * max(1, stretch) * 0.70710678
        let trailRadius = settings.trails.trailLength > 0 ? velocityMagnitude * settings.trails.trailLength : 0
        return billboardRadius + trailRadius
    }

    private func estimatedMaximumParticleSize(startSize: Float, endSize: Float) -> Float {
        let range = settings.appearance.sizeCurve.conservativeValueRange()
        let delta = endSize - startSize
        return max(0,
                   startSize + delta * range.min,
                   startSize + delta * range.max)
    }

    private func accumulateSubEmitterExpansion(rule: ParticleSubEmitter,
                                               accelerationMagnitude: Float,
                                               maxDistance: inout Float,
                                               maxVelocity: inout Float) {
        let velocity = estimatedVelocityMagnitude(startVelocity: rule.startVelocity,
                                                  randomness: rule.velocityRandomness)
        let travel = estimatedTravelDistance(lifetime: rule.lifetime,
                                             velocityMagnitude: velocity,
                                             accelerationMagnitude: accelerationMagnitude)
        let depth = Float(max(1, rule.maxDepth))
        maxDistance = max(maxDistance, travel * depth)
        maxVelocity = max(maxVelocity, velocity)
    }
}

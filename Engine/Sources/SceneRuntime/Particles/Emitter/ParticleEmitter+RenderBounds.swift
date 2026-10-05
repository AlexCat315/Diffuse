import EngineKernel
import SIMDCompat

extension ParticleEmitter {
    public func effectiveRenderBoundsRadius() -> Float {
        switch renderBoundsMode {
        case .disabled:
            return 0
        case .manual:
            return max(0, renderBoundsRadius)
        case .automatic:
            return estimatedRenderBoundsRadius()
        }
    }

    public func renderLODScale(cameraDistance: Float) -> Float {
        guard renderLODEndDistance > renderLODStartDistance else {
            return 1
        }
        let t = simd_clamp((max(0, cameraDistance) - renderLODStartDistance)
                           / (renderLODEndDistance - renderLODStartDistance), 0, 1)
        return 1 + (renderLODMinParticleScale - 1) * t
    }

    public func effectiveMaxRenderedParticles(cameraDistance: Float, liveParticleCount: Int) -> Int {
        let liveCount = max(0, liveParticleCount)
        guard liveCount > 0 else { return 0 }
        let baseLimit = maxRenderedParticles > 0 ? min(maxRenderedParticles, liveCount) : liveCount
        let scale = renderLODScale(cameraDistance: cameraDistance)
        guard scale > 0 else { return 0 }
        return min(baseLimit, max(1, Int(ceil(Float(baseLimit) * scale))))
    }

    public func estimatedRenderBoundsRadius() -> Float {
        let primaryLifetime = max(0.0001, lifetime + lifetimeRandomness)
        let spawnExtent = estimatedSpawnExtent()
        let primaryVelocity = estimatedVelocityMagnitude(startVelocity: startVelocity,
                                                         randomness: velocityRandomness)
        let acceleration = estimatedAccelerationMagnitude()
        let primaryTravel = estimatedTravelDistance(lifetime: primaryLifetime,
                                                    velocityMagnitude: primaryVelocity,
                                                    accelerationMagnitude: acceleration)
        let childTravel = estimatedSubEmitterExpansion(accelerationMagnitude: acceleration)
        let billboardRadius = estimatedBillboardRadius(velocityMagnitude: max(primaryVelocity, childTravel.velocity))
        let forceExtent: Float
        if forceMode != .none, forceRadius > 0 {
            forceExtent = simd_length(forceCenter) + forceRadius
        } else {
            forceExtent = 0
        }
        let radius = spawnExtent + primaryTravel + childTravel.distance + billboardRadius + forceExtent
        return radius.isFinite ? max(0, radius) : max(0, renderBoundsRadius)
    }

    private func estimatedSpawnExtent() -> Float {
        switch emissionShape {
        case .sphere:
            return spawnRadius
        case .box:
            return simd_length(boxHalfExtents)
        case .cone:
            return sqrt(coneRadius * coneRadius + coneHeight * coneHeight)
        }
    }

    private func estimatedVelocityMagnitude(startVelocity: SIMD3<Float>,
                                            randomness: SIMD3<Float>) -> Float {
        simd_length(startVelocity) + simd_length(randomness)
    }

    private func estimatedAccelerationMagnitude() -> Float {
        simd_length(gravity) + noiseStrength + abs(forceStrength) + abs(vectorFieldStrength)
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
        for rule in subEmitters {
            accumulateSubEmitterExpansion(rule: rule,
                                          accelerationMagnitude: accelerationMagnitude,
                                          maxDistance: &maxDistance,
                                          maxVelocity: &maxVelocity)
        }
        return (maxDistance, maxVelocity)
    }

    private func estimatedBillboardRadius(velocityMagnitude: Float) -> Float {
        var size = estimatedMaximumParticleSize(startSize: startSize, endSize: endSize)
        size = max(size, estimatedMaximumParticleSize(startSize: subEmitterStartSize,
                                                      endSize: subEmitterEndSize))
        for rule in subEmitters {
            size = max(size, estimatedMaximumParticleSize(startSize: rule.startSize,
                                                          endSize: rule.endSize))
        }
        let sizeScale = max(0, 1 + sizeRandomness)
        let stretch = renderAlignment == .velocity
            ? min(velocityStretchMax, max(1, 1 + velocityMagnitude * velocityStretchScale))
            : 1
        let billboardRadius = max(0, size) * sizeScale * max(1, stretch) * 0.70710678
        let trailRadius = trailLength > 0 ? velocityMagnitude * trailLength : 0
        return billboardRadius + trailRadius
    }

    private func estimatedMaximumParticleSize(startSize: Float, endSize: Float) -> Float {
        let range = sizeCurve.conservativeValueRange()
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

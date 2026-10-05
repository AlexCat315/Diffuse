import SIMDCompat

/// Transient CPU simulation data. Authoring configuration survives a clear;
/// all timing, live pools and feedback are reset together, preserving the PRNG.
struct ParticleEmitterRuntimeState: Sendable, Equatable {
    var particles: [Particle] = []
    var lastFrameSpawnedParticles: [Particle] = []
    var lastFrameEvents: [ParticleEvent] = []
    var lastFrameStats: ParticleEmitterFrameStats = .empty
    var emitterAge: Float = 0
    var emissionAccumulator: Float = 0
    var distanceEmissionAccumulator: Float = 0
    var burstAccumulator: Float = 0
    var burstSpawnAccumulator: Float = 0
    var previousEmitterPosition: SIMD3<Float>?
    var hasPrewarmed = false
    var rngState: UInt64 = 0x9E3779B9

    mutating func clear() {
        particles.removeAll(keepingCapacity: true)
        lastFrameSpawnedParticles.removeAll(keepingCapacity: true)
        lastFrameEvents.removeAll(keepingCapacity: true)
        lastFrameStats = .empty
        emitterAge = 0
        emissionAccumulator = 0
        distanceEmissionAccumulator = 0
        burstAccumulator = 0
        burstSpawnAccumulator = 0
        previousEmitterPosition = nil
        hasPrewarmed = false
    }
}

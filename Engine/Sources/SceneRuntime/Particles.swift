import EngineKernel
import SIMDCompat

/// A single live particle owned by a `ParticleEmitter`. Positions/velocities are in the
/// emitter's local space; `size`/`color` are re-derived from `age` each step so the render
/// backend can consume them directly without re-evaluating the gradient.
public struct Particle: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public var age: Float
    public var lifetime: Float
    public var size: Float
    public var color: SIMD4<Float>

    public init(position: SIMD3<Float>, velocity: SIMD3<Float>,
                age: Float = 0, lifetime: Float,
                size: Float = 1, color: SIMD4<Float> = .init(1, 1, 1, 1)) {
        self.position = position
        self.velocity = velocity
        self.age = age
        self.lifetime = lifetime
        self.size = size
        self.color = color
    }

    /// Normalized life progress in 0…1.
    public var normalizedAge: Float { lifetime > 0 ? simd_clamp(age / lifetime, 0, 1) : 1 }
}

/// CPU particle emitter component. Holds both the emission configuration and the live
/// particle pool; `advance(deltaTime:)` integrates motion, ages/culls particles, and spawns
/// new ones from a continuous rate. Spawning is driven by a seeded PRNG so simulations are
/// fully deterministic and unit-testable.
public struct ParticleEmitter: RuntimeComponent, Sendable, Equatable {
    // Emission config
    public var isEmitting: Bool
    public var looping: Bool
    /// Particles spawned per second from the continuous emitter.
    public var emissionRate: Float
    public var maxParticles: Int
    public var lifetime: Float
    public var lifetimeRandomness: Float
    /// Spawn offset from the entity origin (local space).
    public var originOffset: SIMD3<Float>
    /// Particles spawn within a sphere of this radius around `originOffset`.
    public var spawnRadius: Float
    public var startVelocity: SIMD3<Float>
    public var velocityRandomness: SIMD3<Float>
    public var gravity: SIMD3<Float>
    public var startSize: Float
    public var endSize: Float
    public var startColor: SIMD4<Float>
    public var endColor: SIMD4<Float>
    public var seed: UInt64

    // Live state
    public private(set) var particles: [Particle]
    private var emissionAccumulator: Float
    private var rngState: UInt64

    public init(
        isEmitting: Bool = true,
        looping: Bool = true,
        emissionRate: Float = 10,
        maxParticles: Int = 256,
        lifetime: Float = 2,
        lifetimeRandomness: Float = 0,
        originOffset: SIMD3<Float> = .zero,
        spawnRadius: Float = 0,
        startVelocity: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        velocityRandomness: SIMD3<Float> = .zero,
        gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0),
        startSize: Float = 1,
        endSize: Float = 0,
        startColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        endColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0),
        seed: UInt64 = 0x9E3779B9
    ) {
        self.isEmitting = isEmitting
        self.looping = looping
        self.emissionRate = max(0, emissionRate)
        self.maxParticles = max(0, maxParticles)
        self.lifetime = max(0, lifetime)
        self.lifetimeRandomness = max(0, lifetimeRandomness)
        self.originOffset = originOffset
        self.spawnRadius = max(0, spawnRadius)
        self.startVelocity = startVelocity
        self.velocityRandomness = velocityRandomness
        self.gravity = gravity
        self.startSize = startSize
        self.endSize = endSize
        self.startColor = startColor
        self.endColor = endColor
        self.seed = seed
        self.particles = []
        self.emissionAccumulator = 0
        self.rngState = seed
    }

    /// Number of currently-alive particles.
    public var aliveCount: Int { particles.count }

    /// Advances the simulation by `deltaTime` seconds: integrates existing particles, culls
    /// expired ones, then spawns from the continuous emission rate (capped at `maxParticles`).
    public mutating func advance(deltaTime: Double) {
        guard deltaTime > 0 else { return }
        let dt = Float(deltaTime)

        var survivors: [Particle] = []
        survivors.reserveCapacity(particles.count)
        for var p in particles {
            p.velocity += gravity * dt
            p.position += p.velocity * dt
            p.age += dt
            if p.age < p.lifetime {
                refreshAppearance(&p)
                survivors.append(p)
            }
        }
        particles = survivors

        guard isEmitting, emissionRate > 0 else { return }
        emissionAccumulator += emissionRate * dt
        let toSpawn = Int(emissionAccumulator)
        if toSpawn > 0 {
            emissionAccumulator -= Float(toSpawn)
            spawn(toSpawn)
        }
    }

    /// Spawns `count` particles immediately (a burst), independent of the emission rate.
    /// Honors the `maxParticles` cap.
    public mutating func emit(_ count: Int) { spawn(count) }

    /// Removes all live particles and resets emission timing.
    public mutating func clear() {
        particles.removeAll(keepingCapacity: true)
        emissionAccumulator = 0
    }

    // MARK: - Internals

    private mutating func spawn(_ count: Int) {
        guard count > 0, maxParticles > 0 else { return }
        let room = maxParticles - particles.count
        let n = min(count, max(0, room))
        for _ in 0..<n {
            let offset = randomInSphere() * spawnRadius
            let jitter = SIMD3<Float>(nextSigned() * velocityRandomness.x,
                                      nextSigned() * velocityRandomness.y,
                                      nextSigned() * velocityRandomness.z)
            let life = max(0.0001, lifetime + nextSigned() * lifetimeRandomness)
            var p = Particle(position: originOffset + offset,
                             velocity: startVelocity + jitter,
                             lifetime: life)
            refreshAppearance(&p)
            particles.append(p)
        }
    }

    private func refreshAppearance(_ p: inout Particle) {
        let t = p.normalizedAge
        p.size = startSize + (endSize - startSize) * t
        p.color = startColor + (endColor - startColor) * t
    }

    private mutating func nextUnit() -> Float {
        // SplitMix64 → [0, 1)
        rngState &+= 0x9E3779B97F4A7C15
        var z = rngState
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return Float(z >> 40) * (1.0 / 16_777_216.0)
    }

    private mutating func nextSigned() -> Float { nextUnit() * 2 - 1 }

    private mutating func randomInSphere() -> SIMD3<Float> {
        guard spawnRadius > 0 else { return .zero }
        // Rejection sampling keeps the distribution uniform inside the unit sphere.
        for _ in 0..<8 {
            let v = SIMD3<Float>(nextSigned(), nextSigned(), nextSigned())
            if simd_length_squared(v) <= 1 { return v }
        }
        return .zero
    }
}

public extension SceneRuntime {
    /// Advances every `ParticleEmitter` in the scene by `deltaTime` seconds.
    /// Returns the number of emitters stepped.
    @discardableResult
    mutating func advanceParticles(deltaTime: Double) -> Int {
        updateComponents(ParticleEmitter.self) { _, emitter in
            emitter.advance(deltaTime: deltaTime)
        }
    }
}

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
    public var sizeScale: Float
    public var size: Float
    public var color: SIMD4<Float>

    public init(position: SIMD3<Float>, velocity: SIMD3<Float>,
                age: Float = 0, lifetime: Float,
                sizeScale: Float = 1,
                size: Float = 1, color: SIMD4<Float> = .init(1, 1, 1, 1)) {
        self.position = position
        self.velocity = velocity
        self.age = age
        self.lifetime = lifetime
        self.sizeScale = sizeScale
        self.size = size
        self.color = color
    }

    /// Normalized life progress in 0…1.
    public var normalizedAge: Float { lifetime > 0 ? simd_clamp(age / lifetime, 0, 1) : 1 }
}

public enum ParticleEmissionShape: String, CaseIterable, Codable, Sendable, Equatable {
    case sphere
    case box
    case cone
}

public enum ParticleCollisionMode: String, CaseIterable, Codable, Sendable, Equatable {
    case none
    case localPlane
    case worldPlane
}

public struct ParticleCurveKeyframe: Codable, Sendable, Equatable, Hashable {
    public var time: Float
    public var value: Float

    public init(time: Float, value: Float) {
        self.time = simd_clamp(time, 0, 1)
        self.value = value
    }
}

public enum ParticleCurve: RawRepresentable, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case keyframes([ParticleCurveKeyframe])

    public typealias RawValue = String

    public static var allCases: [ParticleCurve] {
        [.linear, .easeIn, .easeOut, .easeInOut]
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "linear":
            self = .linear
        case "easeIn":
            self = .easeIn
        case "easeOut":
            self = .easeOut
        case "easeInOut":
            self = .easeInOut
        case "keyframes":
            self = .keyframes([])
        default:
            return nil
        }
    }

    public var rawValue: String {
        switch self {
        case .linear:
            return "linear"
        case .easeIn:
            return "easeIn"
        case .easeOut:
            return "easeOut"
        case .easeInOut:
            return "easeInOut"
        case .keyframes:
            return "keyframes"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case keyframes
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let rawValue = try? container.decode(String.self),
           let curve = ParticleCurve(rawValue: rawValue) {
            self = curve
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "linear"
        if type == "keyframes" {
            self = .keyframes(try container.decodeIfPresent([ParticleCurveKeyframe].self,
                                                            forKey: .keyframes) ?? [])
        } else {
            self = ParticleCurve(rawValue: type) ?? .linear
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .linear, .easeIn, .easeOut, .easeInOut:
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        case .keyframes(let keyframes):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rawValue, forKey: .type)
            try container.encode(keyframes, forKey: .keyframes)
        }
    }

    public func evaluate(at t: Float) -> Float {
        let x = simd_clamp(t, 0, 1)
        switch self {
        case .linear:
            return x
        case .easeIn:
            return x * x
        case .easeOut:
            return 1 - (1 - x) * (1 - x)
        case .easeInOut:
            if x < 0.5 { return 2 * x * x }
            let inverse = 1 - x
            return 1 - 2 * inverse * inverse
        case .keyframes(let keyframes):
            return Self.evaluateKeyframes(keyframes, at: x)
        }
    }

    private static func evaluateKeyframes(_ keyframes: [ParticleCurveKeyframe], at t: Float) -> Float {
        guard !keyframes.isEmpty else { return t }
        let sorted = keyframes.enumerated()
            .sorted {
                if $0.element.time == $1.element.time {
                    return $0.offset < $1.offset
                }
                return $0.element.time < $1.element.time
            }
            .map(\.element)
        guard let first = sorted.first else { return t }
        guard let last = sorted.last else { return first.value }
        if t <= first.time { return first.value }
        if t >= last.time { return last.value }

        for index in 1..<sorted.count {
            let lower = sorted[index - 1]
            let upper = sorted[index]
            guard t <= upper.time else { continue }
            let span = upper.time - lower.time
            guard span > 0.0001 else { return upper.value }
            let localT = (t - lower.time) / span
            return lower.value + (upper.value - lower.value) * localT
        }
        return last.value
    }
}

public enum ParticleBlendMode: String, CaseIterable, Codable, Sendable, Equatable {
    case alpha
    case additive
}

/// CPU particle emitter component. Holds both the emission configuration and the live
/// particle pool; `advance(deltaTime:)` integrates motion, ages/culls particles, and spawns
/// new ones from a continuous rate. Spawning is driven by a seeded PRNG so simulations are
/// fully deterministic and unit-testable.
public struct ParticleEmitter: RuntimeComponent, Sendable, Equatable {
    // Emission config
    public var isEmitting: Bool
    public var looping: Bool
    /// Seconds the emitter can produce particles before a non-looping emitter stops. Zero means infinite.
    public var duration: Float
    /// Particles spawned per second from the continuous emitter.
    public var emissionRate: Float
    /// Particles spawned each burst tick. Zero disables scheduled bursts.
    public var burstCount: Int
    /// Seconds between scheduled bursts when `burstCount > 0`.
    public var burstInterval: Float
    public var maxParticles: Int
    public var lifetime: Float
    public var lifetimeRandomness: Float
    /// Spawn offset from the entity origin (local space).
    public var originOffset: SIMD3<Float>
    /// Particles spawn within a sphere of this radius around `originOffset`.
    public var spawnRadius: Float
    public var emissionShape: ParticleEmissionShape
    /// Half-size of the spawn box when `emissionShape == .box`.
    public var boxHalfExtents: SIMD3<Float>
    /// Base radius of the spawn cone when `emissionShape == .cone`.
    public var coneRadius: Float
    /// Height of the spawn cone when `emissionShape == .cone`.
    public var coneHeight: Float
    public var startVelocity: SIMD3<Float>
    public var velocityRandomness: SIMD3<Float>
    public var gravity: SIMD3<Float>
    /// Deterministic procedural acceleration strength applied each tick.
    public var noiseStrength: Float
    /// Spatial frequency for procedural noise; higher values vary faster over space.
    public var noiseScale: Float
    /// Lifetime-time scroll speed for procedural noise.
    public var noiseSpeed: Float
    public var collisionMode: ParticleCollisionMode
    /// Y position of the collision plane. Interpreted in local or world space based on `collisionMode`.
    public var collisionPlaneY: Float
    /// Bounce factor applied to velocity normal to the collision plane.
    public var collisionRestitution: Float
    /// Fraction of tangent velocity removed on plane impact.
    public var collisionDamping: Float
    public var startSize: Float
    public var endSize: Float
    /// Fractional random size variation applied once per particle spawn. A value of 0.25 means ±25%.
    public var sizeRandomness: Float
    public var sizeCurve: ParticleCurve
    public var startColor: SIMD4<Float>
    public var endColor: SIMD4<Float>
    public var colorCurve: ParticleCurve
    public var blendMode: ParticleBlendMode
    public var seed: UInt64

    // Live state
    public private(set) var particles: [Particle]
    private var emitterAge: Float
    private var emissionAccumulator: Float
    private var burstAccumulator: Float
    private var rngState: UInt64

    public init(
        isEmitting: Bool = true,
        looping: Bool = true,
        duration: Float = 0,
        emissionRate: Float = 10,
        burstCount: Int = 0,
        burstInterval: Float = 0,
        maxParticles: Int = 256,
        lifetime: Float = 2,
        lifetimeRandomness: Float = 0,
        originOffset: SIMD3<Float> = .zero,
        spawnRadius: Float = 0,
        emissionShape: ParticleEmissionShape = .sphere,
        boxHalfExtents: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5),
        coneRadius: Float = 0.5,
        coneHeight: Float = 1,
        startVelocity: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        velocityRandomness: SIMD3<Float> = .zero,
        gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0),
        noiseStrength: Float = 0,
        noiseScale: Float = 1,
        noiseSpeed: Float = 1,
        collisionMode: ParticleCollisionMode = .none,
        collisionPlaneY: Float = 0,
        collisionRestitution: Float = 0.5,
        collisionDamping: Float = 0,
        startSize: Float = 1,
        endSize: Float = 0,
        sizeRandomness: Float = 0,
        sizeCurve: ParticleCurve = .linear,
        startColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        endColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0),
        colorCurve: ParticleCurve = .linear,
        blendMode: ParticleBlendMode = .alpha,
        seed: UInt64 = 0x9E3779B9
    ) {
        self.isEmitting = isEmitting
        self.looping = looping
        self.duration = max(0, duration)
        self.emissionRate = max(0, emissionRate)
        self.burstCount = max(0, burstCount)
        self.burstInterval = max(0, burstInterval)
        self.maxParticles = max(0, maxParticles)
        self.lifetime = max(0, lifetime)
        self.lifetimeRandomness = max(0, lifetimeRandomness)
        self.originOffset = originOffset
        self.spawnRadius = max(0, spawnRadius)
        self.emissionShape = emissionShape
        self.boxHalfExtents = SIMD3<Float>(
            max(0, boxHalfExtents.x),
            max(0, boxHalfExtents.y),
            max(0, boxHalfExtents.z)
        )
        self.coneRadius = max(0, coneRadius)
        self.coneHeight = max(0, coneHeight)
        self.startVelocity = startVelocity
        self.velocityRandomness = velocityRandomness
        self.gravity = gravity
        self.noiseStrength = max(0, noiseStrength)
        self.noiseScale = max(0.0001, noiseScale)
        self.noiseSpeed = max(0, noiseSpeed)
        self.collisionMode = collisionMode
        self.collisionPlaneY = collisionPlaneY
        self.collisionRestitution = simd_clamp(collisionRestitution, 0, 1)
        self.collisionDamping = simd_clamp(collisionDamping, 0, 1)
        self.startSize = startSize
        self.endSize = endSize
        self.sizeRandomness = max(0, sizeRandomness)
        self.sizeCurve = sizeCurve
        self.startColor = startColor
        self.endColor = endColor
        self.colorCurve = colorCurve
        self.blendMode = blendMode
        self.seed = seed
        self.particles = []
        self.emitterAge = 0
        self.emissionAccumulator = 0
        self.burstAccumulator = 0
        self.rngState = seed
    }

    /// Number of currently-alive particles.
    public var aliveCount: Int { particles.count }

    /// Advances the simulation by `deltaTime` seconds: integrates existing particles, culls
    /// expired ones, then spawns from the continuous emission rate and scheduled bursts
    /// (capped at `maxParticles`).
    public mutating func advance(deltaTime: Double, worldTransform: simd_float4x4? = nil) {
        guard deltaTime > 0 else { return }
        let dt = Float(deltaTime)
        let collisionContext = makeCollisionContext(worldTransform: worldTransform)

        var survivors: [Particle] = []
        survivors.reserveCapacity(particles.count)
        for var p in particles {
            p.velocity += gravity * dt
            p.velocity += noiseForce(position: p.position, age: p.age) * dt
            p.position += p.velocity * dt
            applyCollision(to: &p, context: collisionContext)
            p.age += dt
            if p.age < p.lifetime {
                refreshAppearance(&p)
                survivors.append(p)
            }
        }
        particles = survivors

        guard isEmitting else { return }
        let emissionDt = activeEmissionDelta(dt)
        guard emissionDt > 0 else { return }
        if emissionRate > 0 {
            emissionAccumulator += emissionRate * emissionDt
            let toSpawn = Int(emissionAccumulator)
            if toSpawn > 0 {
                emissionAccumulator -= Float(toSpawn)
                spawn(toSpawn)
            }
        }
        if burstCount > 0, burstInterval > 0 {
            burstAccumulator += emissionDt
            let bursts = Int(burstAccumulator / burstInterval)
            if bursts > 0 {
                burstAccumulator -= Float(bursts) * burstInterval
                spawn(bursts * burstCount)
            }
        }
    }

    /// Spawns `count` particles immediately (a burst), independent of the emission rate.
    /// Honors the `maxParticles` cap.
    public mutating func emit(_ count: Int) { spawn(count) }

    /// Removes all live particles and resets emission timing.
    public mutating func clear() {
        particles.removeAll(keepingCapacity: true)
        emitterAge = 0
        emissionAccumulator = 0
        burstAccumulator = 0
    }

    // MARK: - Internals

    private mutating func activeEmissionDelta(_ dt: Float) -> Float {
        guard duration > 0 else { return dt }
        if looping {
            emitterAge = (emitterAge + dt).truncatingRemainder(dividingBy: duration)
            return dt
        }

        let remaining = max(0, duration - emitterAge)
        emitterAge += dt
        return min(dt, remaining)
    }

    private mutating func spawn(_ count: Int) {
        guard count > 0, maxParticles > 0 else { return }
        let room = maxParticles - particles.count
        let n = min(count, max(0, room))
        for _ in 0..<n {
            let offset = spawnOffset()
            let jitter = SIMD3<Float>(nextSigned() * velocityRandomness.x,
                                      nextSigned() * velocityRandomness.y,
                                      nextSigned() * velocityRandomness.z)
            let life = max(0.0001, lifetime + nextSigned() * lifetimeRandomness)
            let sizeScale = max(0, 1 + nextSigned() * sizeRandomness)
            var p = Particle(position: originOffset + offset,
                             velocity: startVelocity + jitter,
                             lifetime: life,
                             sizeScale: sizeScale)
            refreshAppearance(&p)
            particles.append(p)
        }
    }

    private func refreshAppearance(_ p: inout Particle) {
        let t = p.normalizedAge
        let sizeT = sizeCurve.evaluate(at: t)
        let colorT = colorCurve.evaluate(at: t)
        p.size = (startSize + (endSize - startSize) * sizeT) * p.sizeScale
        p.color = startColor + (endColor - startColor) * colorT
    }

    private func noiseForce(position: SIMD3<Float>, age: Float) -> SIMD3<Float> {
        guard noiseStrength > 0 else { return .zero }
        let p = position * noiseScale
        let phase = age * noiseSpeed + Float(seed & 0xFFFF) * 0.0001
        return SIMD3<Float>(
            sineWave(p.x * 12.9898 + p.y * 78.233 + p.z * 37.719 + phase),
            sineWave(p.y * 26.651 + p.z * 91.191 + p.x * 13.153 + phase + 2.17),
            sineWave(p.z * 54.123 + p.x * 44.531 + p.y * 9.151 + phase + 4.31)
        ) * noiseStrength
    }

    private func sineWave(_ x: Float) -> Float {
        Float(sin(Double(x)))
    }

    private struct ParticleCollisionContext {
        var toWorld: simd_float4x4
        var toLocal: simd_float4x4
    }

    private func makeCollisionContext(worldTransform: simd_float4x4?) -> ParticleCollisionContext? {
        guard collisionMode == .worldPlane else { return nil }
        let toWorld = worldTransform ?? matrix_identity_float4x4
        return ParticleCollisionContext(toWorld: toWorld, toLocal: simd_inverse(toWorld))
    }

    private func applyCollision(to p: inout Particle, context: ParticleCollisionContext?) {
        switch collisionMode {
        case .none:
            return
        case .localPlane:
            guard p.position.y < collisionPlaneY else { return }
            p.position.y = collisionPlaneY
            guard p.velocity.y < 0 else { return }
            p.velocity.y = -p.velocity.y * collisionRestitution
            let tangentScale = 1 - collisionDamping
            p.velocity.x *= tangentScale
            p.velocity.z *= tangentScale
        case .worldPlane:
            let context = context ?? ParticleCollisionContext(
                toWorld: matrix_identity_float4x4,
                toLocal: matrix_identity_float4x4
            )
            let worldPosition4 = context.toWorld * SIMD4<Float>(p.position, 1)
            guard worldPosition4.y < collisionPlaneY else { return }

            var clampedWorldPosition = worldPosition4
            clampedWorldPosition.y = collisionPlaneY
            let localPosition4 = context.toLocal * clampedWorldPosition
            if abs(localPosition4.w) > 0.0001 {
                p.position = SIMD3<Float>(
                    localPosition4.x / localPosition4.w,
                    localPosition4.y / localPosition4.w,
                    localPosition4.z / localPosition4.w
                )
            } else {
                p.position = SIMD3<Float>(localPosition4.x, localPosition4.y, localPosition4.z)
            }

            let worldVelocity4 = context.toWorld * SIMD4<Float>(p.velocity, 0)
            guard worldVelocity4.y < 0 else { return }

            let tangentScale = 1 - collisionDamping
            let bouncedWorldVelocity = SIMD4<Float>(
                worldVelocity4.x * tangentScale,
                -worldVelocity4.y * collisionRestitution,
                worldVelocity4.z * tangentScale,
                0
            )
            let localVelocity4 = context.toLocal * bouncedWorldVelocity
            p.velocity = SIMD3<Float>(localVelocity4.x, localVelocity4.y, localVelocity4.z)
        }
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

    private mutating func spawnOffset() -> SIMD3<Float> {
        switch emissionShape {
        case .sphere:
            return randomInSphere() * spawnRadius
        case .box:
            return randomInBox()
        case .cone:
            return randomInCone()
        }
    }

    private mutating func randomInSphere() -> SIMD3<Float> {
        guard spawnRadius > 0 else { return .zero }
        // Rejection sampling keeps the distribution uniform inside the unit sphere.
        for _ in 0..<8 {
            let v = SIMD3<Float>(nextSigned(), nextSigned(), nextSigned())
            if simd_length_squared(v) <= 1 { return v }
        }
        return .zero
    }

    private mutating func randomInBox() -> SIMD3<Float> {
        SIMD3<Float>(
            nextSigned() * boxHalfExtents.x,
            nextSigned() * boxHalfExtents.y,
            nextSigned() * boxHalfExtents.z
        )
    }

    private mutating func randomInCone() -> SIMD3<Float> {
        guard coneRadius > 0, coneHeight > 0 else { return .zero }
        let axis = normalizedOrDefault(startVelocity, SIMD3<Float>(0, 1, 0))
        let basis = coneBasis(axis: axis)
        let height = coneHeight * cbrt(nextUnit())
        let diskRadius = coneRadius * (height / coneHeight) * sqrt(nextUnit())
        let angle = nextUnit() * 2 * Float.pi
        return axis * height
            + basis.tangent * (cos(angle) * diskRadius)
            + basis.bitangent * (sin(angle) * diskRadius)
    }

    private func normalizedOrDefault(_ v: SIMD3<Float>, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
        let len = simd_length(v)
        guard len > 0.0001 else { return fallback }
        return v / len
    }

    private func coneBasis(axis: SIMD3<Float>) -> (tangent: SIMD3<Float>, bitangent: SIMD3<Float>) {
        let reference = abs(axis.y) < 0.99 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let tangent = normalizedOrDefault(simd_cross(reference, axis), SIMD3<Float>(1, 0, 0))
        let bitangent = normalizedOrDefault(simd_cross(axis, tangent), SIMD3<Float>(0, 0, 1))
        return (tangent, bitangent)
    }
}

public extension SceneRuntime {
    /// Advances every `ParticleEmitter` in the scene by `deltaTime` seconds.
    /// Returns the number of emitters stepped.
    @discardableResult
    mutating func advanceParticles(deltaTime: Double) -> Int {
        let particleEntities = entities(with: ParticleEmitter.self)
        let worldTransforms = Dictionary(uniqueKeysWithValues: particleEntities.map {
            ($0, worldTransform(for: $0)?.matrix ?? matrix_identity_float4x4)
        })
        return updateComponents(ParticleEmitter.self) { entity, emitter in
            emitter.advance(deltaTime: deltaTime, worldTransform: worldTransforms[entity] ?? matrix_identity_float4x4)
        }
    }

    /// Emits particles immediately from one entity's `ParticleEmitter`.
    /// Returns false when the entity has no particle emitter.
    @discardableResult
    mutating func emitParticles(from entity: EntityID, count: Int) -> Bool {
        updateComponent(ParticleEmitter.self, for: entity) { emitter in
            emitter.emit(count)
        }
    }
}

import EngineKernel
import SIMDCompat

/// A single live particle owned by a `ParticleEmitter`. Positions/velocities are stored in
/// the emitter's configured simulation space; `size`/`color` are re-derived from `age` each
/// step so the render backend can consume them directly without re-evaluating the gradient.
public struct Particle: Sendable, Equatable {
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public var age: Float
    public var lifetime: Float
    public var sizeScale: Float
    public var rotation: Float
    public var angularVelocity: Float
    public var size: Float
    public var color: SIMD4<Float>
    public var generation: UInt8
    public var appearanceIndex: UInt16

    public init(position: SIMD3<Float>, velocity: SIMD3<Float>,
                age: Float = 0, lifetime: Float,
                sizeScale: Float = 1,
                rotation: Float = 0,
                angularVelocity: Float = 0,
                size: Float = 1, color: SIMD4<Float> = .init(1, 1, 1, 1),
                generation: UInt8 = 0,
                appearanceIndex: UInt16 = 0) {
        self.position = position
        self.velocity = velocity
        self.age = age
        self.lifetime = lifetime
        self.sizeScale = sizeScale
        self.rotation = rotation
        self.angularVelocity = angularVelocity
        self.size = size
        self.color = color
        self.generation = generation
        self.appearanceIndex = appearanceIndex
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

public enum ParticleSimulationSpace: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    /// Particles are stored in emitter-local space and follow the entity transform.
    case local
    /// Particles are stored in world space after spawning and remain independent of later emitter motion.
    case world
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
    case constant(Float)
    case linear
    case easeIn
    case easeOut
    case easeInOut
    case keyframes([ParticleCurveKeyframe])

    public typealias RawValue = String

    public static var allCases: [ParticleCurve] {
        [.constant(1), .linear, .easeIn, .easeOut, .easeInOut]
    }

    public init?(rawValue: String) {
        switch rawValue {
        case "constant":
            self = .constant(1)
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
        case .constant:
            return "constant"
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
        case value
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
        if type == "constant" {
            self = .constant(try container.decodeIfPresent(Float.self, forKey: .value) ?? 1)
        } else if type == "keyframes" {
            self = .keyframes(try container.decodeIfPresent([ParticleCurveKeyframe].self,
                                                            forKey: .keyframes) ?? [])
        } else {
            self = ParticleCurve(rawValue: type) ?? .linear
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .constant(let value):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(rawValue, forKey: .type)
            try container.encode(value, forKey: .value)
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
        case .constant(let value):
            return value
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

public enum ParticleBlendMode: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case alpha
    case additive
}

public enum ParticleRenderAlignment: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case billboard
    case velocity
}

public enum ParticleForceMode: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case none
    case radial
    case vortex
}

public enum ParticleSubEmitterTrigger: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case none
    case death
    case collision
}

public struct ParticleSubEmitter: Codable, Sendable, Equatable {
    public var trigger: ParticleSubEmitterTrigger
    public var burstCount: Int
    public var probability: Float
    public var maxDepth: Int
    public var inheritVelocity: Float
    public var lifetime: Float
    public var startVelocity: SIMD3<Float>
    public var velocityRandomness: SIMD3<Float>
    public var startSize: Float
    public var endSize: Float
    public var startColor: SIMD4<Float>
    public var endColor: SIMD4<Float>

    public init(trigger: ParticleSubEmitterTrigger = .none,
                burstCount: Int = 0,
                probability: Float = 1,
                maxDepth: Int = 1,
                inheritVelocity: Float = 0,
                lifetime: Float = 0.5,
                startVelocity: SIMD3<Float> = .zero,
                velocityRandomness: SIMD3<Float> = .zero,
                startSize: Float = 0.25,
                endSize: Float = 0,
                startColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
                endColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0)) {
        self.trigger = trigger
        self.burstCount = max(0, burstCount)
        self.probability = simd_clamp(probability, 0, 1)
        self.maxDepth = max(0, maxDepth)
        self.inheritVelocity = max(0, inheritVelocity)
        self.lifetime = max(0.0001, lifetime)
        self.startVelocity = startVelocity
        self.velocityRandomness = velocityRandomness
        self.startSize = max(0, startSize)
        self.endSize = max(0, endSize)
        self.startColor = startColor
        self.endColor = endColor
    }

    public var isActive: Bool {
        trigger != .none && burstCount > 0 && probability > 0 && maxDepth > 0
    }
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
    /// Seconds of simulation to run before the first active tick. Useful for ambient effects that should start warm.
    public var prewarmTime: Float
    /// Simulation step used while prewarming; smaller values are more accurate but cost more at startup.
    public var prewarmStep: Float
    /// Particles spawned per second from the continuous emitter.
    public var emissionRate: Float
    /// Multiplier sampled over the emitter duration for continuous emission.
    public var emissionRateCurve: ParticleCurve
    /// Particles spawned per unit traveled by the emitter. Useful for stable trails.
    public var distanceEmissionRate: Float
    /// Multiplier sampled over the emitter duration for distance-based emission.
    public var distanceEmissionRateCurve: ParticleCurve
    /// Particles spawned each burst tick. Zero disables scheduled bursts.
    public var burstCount: Int
    /// Seconds between scheduled bursts when `burstCount > 0`.
    public var burstInterval: Float
    public var maxParticles: Int
    public var lifetime: Float
    public var lifetimeRandomness: Float
    /// Event that can spawn secondary particles from each source particle.
    public var subEmitterTrigger: ParticleSubEmitterTrigger
    /// Secondary particles spawned per matching event.
    public var subEmitterBurstCount: Int
    /// Event chance per source particle in 0...1.
    public var subEmitterProbability: Float
    /// Maximum generation allowed for secondary particles. One allows only direct children.
    public var subEmitterMaxDepth: Int
    /// Fraction of source particle velocity inherited by secondary particles.
    public var subEmitterInheritVelocity: Float
    /// Lifetime assigned to secondary particles.
    public var subEmitterLifetime: Float
    /// Base velocity assigned to secondary particles in simulation space.
    public var subEmitterStartVelocity: SIMD3<Float>
    /// Per-axis random secondary velocity variation.
    public var subEmitterVelocityRandomness: SIMD3<Float>
    /// Start size for secondary particles.
    public var subEmitterStartSize: Float
    /// End size for secondary particles.
    public var subEmitterEndSize: Float
    /// Start color for secondary particles.
    public var subEmitterStartColor: SIMD4<Float>
    /// End color for secondary particles.
    public var subEmitterEndColor: SIMD4<Float>
    /// Additional event-driven secondary emitter rules. These are evaluated after the
    /// legacy single sub-emitter fields above and allow multiple effects per particle event.
    public var subEmitters: [ParticleSubEmitter]
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
    /// Fraction of emitter world velocity inherited by newly spawned particles.
    public var velocityInheritance: Float
    public var gravity: SIMD3<Float>
    /// Deterministic procedural acceleration strength applied each tick.
    public var noiseStrength: Float
    /// Spatial frequency for procedural noise; higher values vary faster over space.
    public var noiseScale: Float
    /// Lifetime-time scroll speed for procedural noise.
    public var noiseSpeed: Float
    /// Optional deterministic force field applied in simulation space.
    public var forceMode: ParticleForceMode
    /// Center of the radial/vortex field in the emitter's simulation space.
    public var forceCenter: SIMD3<Float>
    /// Axis used by vortex forces. Falls back to world/local up when zero.
    public var forceAxis: SIMD3<Float>
    /// Maximum force influence radius. Zero means unbounded.
    public var forceRadius: Float
    /// Acceleration magnitude. Positive radial pushes outward; negative radial attracts.
    public var forceStrength: Float
    /// Radius attenuation exponent. Zero keeps full strength inside the radius.
    public var forceFalloff: Float
    public var collisionMode: ParticleCollisionMode
    public var simulationSpace: ParticleSimulationSpace
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
    /// Billboard rotation in radians assigned at spawn before random variation.
    public var startRotation: Float
    /// Random billboard rotation variation in radians applied once per particle spawn.
    public var rotationRandomness: Float
    /// Billboard angular velocity in radians per second.
    public var angularVelocity: Float
    /// Random angular velocity variation in radians per second applied once per particle spawn.
    public var angularVelocityRandomness: Float
    public var sizeCurve: ParticleCurve
    public var startColor: SIMD4<Float>
    public var endColor: SIMD4<Float>
    public var colorCurve: ParticleCurve
    public var blendMode: ParticleBlendMode
    public var renderAlignment: ParticleRenderAlignment
    /// Additional length per unit of particle speed when `renderAlignment == .velocity`.
    public var velocityStretchScale: Float
    /// Upper bound for velocity-aligned stretch.
    public var velocityStretchMax: Float
    /// Maximum camera distance at which this emitter contributes render particles. Zero disables distance culling.
    public var maxRenderDistance: Float
    /// Range before `maxRenderDistance` over which rendered alpha fades to zero.
    public var renderDistanceFadeRange: Float
    /// Optional editor asset identifier for the image sampled by billboard particles.
    public var textureAssetID: String?
    /// Optional resolved image file path sampled by billboard particles. Nil keeps the
    /// procedural soft-round sprite fallback.
    public var texturePath: String?
    /// Number of columns in the particle texture sheet. One keeps the full texture.
    public var textureSheetColumns: Int
    /// Number of rows in the particle texture sheet. One keeps the full texture.
    public var textureSheetRows: Int
    /// Number of frames used from the sheet, in row-major order.
    public var textureSheetFrameCount: Int
    /// Frames per second for texture sheet playback. Zero maps frames over particle lifetime.
    public var textureSheetFrameRate: Float
    /// Seconds of velocity-based trail rendered behind each particle. Zero disables trails.
    public var trailLength: Float
    /// Additional billboard samples rendered behind each particle for trails.
    public var trailSegments: Int
    /// Size multiplier at the last trail segment.
    public var trailEndSizeScale: Float
    /// Alpha multiplier at the last trail segment.
    public var trailEndAlphaScale: Float
    public var seed: UInt64

    // Live state
    public private(set) var particles: [Particle]
    private var emitterAge: Float
    private var emissionAccumulator: Float
    private var distanceEmissionAccumulator: Float
    private var burstAccumulator: Float
    private var previousEmitterPosition: SIMD3<Float>?
    private var hasPrewarmed: Bool
    private var rngState: UInt64

    public init(
        isEmitting: Bool = true,
        looping: Bool = true,
        duration: Float = 0,
        prewarmTime: Float = 0,
        prewarmStep: Float = 1.0 / 30.0,
        emissionRate: Float = 10,
        emissionRateCurve: ParticleCurve = .constant(1),
        distanceEmissionRate: Float = 0,
        distanceEmissionRateCurve: ParticleCurve = .constant(1),
        burstCount: Int = 0,
        burstInterval: Float = 0,
        maxParticles: Int = 256,
        lifetime: Float = 2,
        lifetimeRandomness: Float = 0,
        subEmitterTrigger: ParticleSubEmitterTrigger = .none,
        subEmitterBurstCount: Int = 0,
        subEmitterProbability: Float = 1,
        subEmitterMaxDepth: Int = 1,
        subEmitterInheritVelocity: Float = 0,
        subEmitterLifetime: Float = 0.5,
        subEmitterStartVelocity: SIMD3<Float> = .zero,
        subEmitterVelocityRandomness: SIMD3<Float> = .zero,
        subEmitterStartSize: Float = 0.25,
        subEmitterEndSize: Float = 0,
        subEmitterStartColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        subEmitterEndColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0),
        subEmitters: [ParticleSubEmitter] = [],
        originOffset: SIMD3<Float> = .zero,
        spawnRadius: Float = 0,
        emissionShape: ParticleEmissionShape = .sphere,
        boxHalfExtents: SIMD3<Float> = SIMD3<Float>(0.5, 0.5, 0.5),
        coneRadius: Float = 0.5,
        coneHeight: Float = 1,
        startVelocity: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        velocityRandomness: SIMD3<Float> = .zero,
        velocityInheritance: Float = 0,
        gravity: SIMD3<Float> = SIMD3<Float>(0, -9.81, 0),
        noiseStrength: Float = 0,
        noiseScale: Float = 1,
        noiseSpeed: Float = 1,
        forceMode: ParticleForceMode = .none,
        forceCenter: SIMD3<Float> = .zero,
        forceAxis: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        forceRadius: Float = 0,
        forceStrength: Float = 0,
        forceFalloff: Float = 1,
        collisionMode: ParticleCollisionMode = .none,
        simulationSpace: ParticleSimulationSpace = .local,
        collisionPlaneY: Float = 0,
        collisionRestitution: Float = 0.5,
        collisionDamping: Float = 0,
        startSize: Float = 1,
        endSize: Float = 0,
        sizeRandomness: Float = 0,
        startRotation: Float = 0,
        rotationRandomness: Float = 0,
        angularVelocity: Float = 0,
        angularVelocityRandomness: Float = 0,
        sizeCurve: ParticleCurve = .linear,
        startColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 1),
        endColor: SIMD4<Float> = SIMD4<Float>(1, 1, 1, 0),
        colorCurve: ParticleCurve = .linear,
        blendMode: ParticleBlendMode = .alpha,
        renderAlignment: ParticleRenderAlignment = .billboard,
        velocityStretchScale: Float = 0,
        velocityStretchMax: Float = 8,
        maxRenderDistance: Float = 0,
        renderDistanceFadeRange: Float = 0,
        textureAssetID: String? = nil,
        texturePath: String? = nil,
        textureSheetColumns: Int = 1,
        textureSheetRows: Int = 1,
        textureSheetFrameCount: Int = 1,
        textureSheetFrameRate: Float = 0,
        trailLength: Float = 0,
        trailSegments: Int = 0,
        trailEndSizeScale: Float = 0.5,
        trailEndAlphaScale: Float = 0,
        seed: UInt64 = 0x9E3779B9
    ) {
        self.isEmitting = isEmitting
        self.looping = looping
        self.duration = max(0, duration)
        self.prewarmTime = max(0, prewarmTime)
        self.prewarmStep = max(1.0 / 240.0, prewarmStep)
        self.emissionRate = max(0, emissionRate)
        self.emissionRateCurve = emissionRateCurve
        self.distanceEmissionRate = max(0, distanceEmissionRate)
        self.distanceEmissionRateCurve = distanceEmissionRateCurve
        self.burstCount = max(0, burstCount)
        self.burstInterval = max(0, burstInterval)
        self.maxParticles = max(0, maxParticles)
        self.lifetime = max(0, lifetime)
        self.lifetimeRandomness = max(0, lifetimeRandomness)
        self.subEmitterTrigger = subEmitterTrigger
        self.subEmitterBurstCount = max(0, subEmitterBurstCount)
        self.subEmitterProbability = simd_clamp(subEmitterProbability, 0, 1)
        self.subEmitterMaxDepth = max(0, subEmitterMaxDepth)
        self.subEmitterInheritVelocity = max(0, subEmitterInheritVelocity)
        self.subEmitterLifetime = max(0.0001, subEmitterLifetime)
        self.subEmitterStartVelocity = subEmitterStartVelocity
        self.subEmitterVelocityRandomness = subEmitterVelocityRandomness
        self.subEmitterStartSize = max(0, subEmitterStartSize)
        self.subEmitterEndSize = max(0, subEmitterEndSize)
        self.subEmitterStartColor = subEmitterStartColor
        self.subEmitterEndColor = subEmitterEndColor
        self.subEmitters = subEmitters.map {
            ParticleSubEmitter(trigger: $0.trigger,
                               burstCount: $0.burstCount,
                               probability: $0.probability,
                               maxDepth: $0.maxDepth,
                               inheritVelocity: $0.inheritVelocity,
                               lifetime: $0.lifetime,
                               startVelocity: $0.startVelocity,
                               velocityRandomness: $0.velocityRandomness,
                               startSize: $0.startSize,
                               endSize: $0.endSize,
                               startColor: $0.startColor,
                               endColor: $0.endColor)
        }
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
        self.velocityInheritance = max(0, velocityInheritance)
        self.gravity = gravity
        self.noiseStrength = max(0, noiseStrength)
        self.noiseScale = max(0.0001, noiseScale)
        self.noiseSpeed = max(0, noiseSpeed)
        self.forceMode = forceMode
        self.forceCenter = forceCenter
        self.forceAxis = forceAxis
        self.forceRadius = max(0, forceRadius)
        self.forceStrength = forceStrength
        self.forceFalloff = max(0, forceFalloff)
        self.collisionMode = collisionMode
        self.simulationSpace = simulationSpace
        self.collisionPlaneY = collisionPlaneY
        self.collisionRestitution = simd_clamp(collisionRestitution, 0, 1)
        self.collisionDamping = simd_clamp(collisionDamping, 0, 1)
        self.startSize = startSize
        self.endSize = endSize
        self.sizeRandomness = max(0, sizeRandomness)
        self.startRotation = startRotation
        self.rotationRandomness = max(0, rotationRandomness)
        self.angularVelocity = angularVelocity
        self.angularVelocityRandomness = max(0, angularVelocityRandomness)
        self.sizeCurve = sizeCurve
        self.startColor = startColor
        self.endColor = endColor
        self.colorCurve = colorCurve
        self.blendMode = blendMode
        self.renderAlignment = renderAlignment
        self.velocityStretchScale = max(0, velocityStretchScale)
        self.velocityStretchMax = max(1, velocityStretchMax)
        self.maxRenderDistance = max(0, maxRenderDistance)
        self.renderDistanceFadeRange = max(0, renderDistanceFadeRange)
        self.textureAssetID = textureAssetID?.isEmpty == true ? nil : textureAssetID
        self.texturePath = texturePath?.isEmpty == true ? nil : texturePath
        self.textureSheetColumns = max(1, textureSheetColumns)
        self.textureSheetRows = max(1, textureSheetRows)
        self.textureSheetFrameCount = max(1, textureSheetFrameCount)
        self.textureSheetFrameRate = max(0, textureSheetFrameRate)
        self.trailLength = max(0, trailLength)
        self.trailSegments = max(0, trailSegments)
        self.trailEndSizeScale = max(0, trailEndSizeScale)
        self.trailEndAlphaScale = simd_clamp(trailEndAlphaScale, 0, 1)
        self.seed = seed
        self.particles = []
        self.emitterAge = 0
        self.emissionAccumulator = 0
        self.distanceEmissionAccumulator = 0
        self.burstAccumulator = 0
        self.previousEmitterPosition = nil
        self.hasPrewarmed = false
        self.rngState = seed
    }

    /// Number of currently-alive particles.
    public var aliveCount: Int { particles.count }

    /// UV rect for a particle's current texture sheet frame: x, y, width, height.
    public func textureUVRect(for particle: Particle) -> SIMD4<Float> {
        let columns = max(1, textureSheetColumns)
        let rows = max(1, textureSheetRows)
        let maxFrames = max(1, columns * rows)
        let frameCount = min(maxFrames, max(1, textureSheetFrameCount))
        let frameIndex: Int
        if textureSheetFrameRate > 0 {
            frameIndex = min(frameCount - 1, max(0, Int(floor(particle.age * textureSheetFrameRate))))
        } else {
            frameIndex = min(frameCount - 1, max(0, Int(floor(particle.normalizedAge * Float(frameCount)))))
        }
        let column = frameIndex % columns
        let row = frameIndex / columns
        let width = 1 / Float(columns)
        let height = 1 / Float(rows)
        return SIMD4<Float>(
            Float(column) * width,
            Float(row) * height,
            width,
            height
        )
    }

    /// Advances the simulation by `deltaTime` seconds: integrates existing particles, culls
    /// expired ones, then spawns from the continuous emission rate and scheduled bursts
    /// (capped at `maxParticles`).
    public mutating func advance(deltaTime: Double, worldTransform: simd_float4x4? = nil) {
        guard deltaTime > 0 else { return }
        runPrewarmIfNeeded(worldTransform: worldTransform)
        advanceStep(deltaTime: Float(deltaTime), worldTransform: worldTransform)
    }

    private mutating func advanceStep(deltaTime dt: Float, worldTransform: simd_float4x4? = nil) {
        guard dt > 0 else { return }
        let currentEmitterPosition = distanceEmitterPosition(worldTransform: worldTransform)
        let inheritedWorldVelocity = inheritedEmitterVelocity(
            from: previousEmitterPosition,
            to: currentEmitterPosition,
            deltaTime: dt
        )
        let collisionContext = simulationSpace == .local
            ? makeCollisionContext(worldTransform: worldTransform)
            : nil

        var survivors: [Particle] = []
        var eventParticles: [Particle] = []
        survivors.reserveCapacity(particles.count)
        for var p in particles {
            p.velocity += gravity * dt
            p.velocity += noiseForce(position: p.position, age: p.age) * dt
            p.velocity += forceAcceleration(position: p.position) * dt
            p.position += p.velocity * dt
            p.rotation += p.angularVelocity * dt
            let collided = applyCollision(to: &p, context: collisionContext)
            if collided {
                spawnSubEmitterParticles(trigger: .collision,
                                         source: p,
                                         survivorsCount: survivors.count,
                                         pending: &eventParticles)
            }
            p.age += dt
            if p.age < p.lifetime {
                refreshAppearance(&p)
                survivors.append(p)
            } else {
                spawnSubEmitterParticles(trigger: .death,
                                         source: p,
                                         survivorsCount: survivors.count,
                                         pending: &eventParticles)
            }
        }
        particles = survivors
        appendEventParticles(eventParticles)

        guard isEmitting else {
            previousEmitterPosition = currentEmitterPosition
            return
        }
        let emissionStep = activeEmissionStep(dt)
        guard emissionStep.delta > 0 else {
            previousEmitterPosition = currentEmitterPosition
            return
        }
        let emissionRateMultiplier = max(0, emissionRateCurve.evaluate(at: emissionStep.normalizedAge))
        if emissionRate > 0, emissionRateMultiplier > 0 {
            emissionAccumulator += emissionRate * emissionRateMultiplier * emissionStep.delta
            let toSpawn = Int(emissionAccumulator)
            if toSpawn > 0 {
                emissionAccumulator -= Float(toSpawn)
                spawn(toSpawn, worldTransform: worldTransform, inheritedWorldVelocity: inheritedWorldVelocity)
            }
        }
        if burstCount > 0, burstInterval > 0 {
            burstAccumulator += emissionStep.delta
            let bursts = Int(burstAccumulator / burstInterval)
            if bursts > 0 {
                burstAccumulator -= Float(bursts) * burstInterval
                spawn(bursts * burstCount,
                      worldTransform: worldTransform,
                      inheritedWorldVelocity: inheritedWorldVelocity)
            }
        }
        let distanceRateMultiplier = max(0, distanceEmissionRateCurve.evaluate(at: emissionStep.normalizedAge))
        spawnDistanceEmission(from: previousEmitterPosition,
                              to: currentEmitterPosition,
                              worldTransform: worldTransform,
                              inheritedWorldVelocity: inheritedWorldVelocity,
                              rateMultiplier: distanceRateMultiplier)
    }

    /// Spawns `count` particles immediately (a burst), independent of the emission rate.
    /// Honors the `maxParticles` cap.
    public mutating func emit(_ count: Int, worldTransform: simd_float4x4? = nil) {
        spawn(count, worldTransform: worldTransform)
    }

    /// Removes all live particles and resets emission timing.
    public mutating func clear() {
        particles.removeAll(keepingCapacity: true)
        emitterAge = 0
        emissionAccumulator = 0
        distanceEmissionAccumulator = 0
        burstAccumulator = 0
        previousEmitterPosition = nil
        hasPrewarmed = false
    }

    // MARK: - Internals

    private struct ParticleSpawnSample {
        var offset: SIMD3<Float>
        var velocityJitter: SIMD3<Float>
        var lifetime: Float
        var sizeScale: Float
        var rotation: Float
        var angularVelocity: Float
    }

    private struct ParticleAppearance {
        var startSize: Float
        var endSize: Float
        var startColor: SIMD4<Float>
        var endColor: SIMD4<Float>
    }

    private mutating func runPrewarmIfNeeded(worldTransform: simd_float4x4?) {
        guard !hasPrewarmed,
              isEmitting,
              prewarmTime > 0,
              maxParticles > 0
        else { return }

        hasPrewarmed = true
        previousEmitterPosition = distanceEmitterPosition(worldTransform: worldTransform)
        var remaining = prewarmTime
        let step = min(max(1.0 / 240.0, prewarmStep), prewarmTime)
        while remaining > 0.0001 {
            let dt = min(step, remaining)
            advanceStep(deltaTime: dt, worldTransform: worldTransform)
            remaining -= dt
        }
        previousEmitterPosition = distanceEmitterPosition(worldTransform: worldTransform)
    }

    private struct ActiveEmissionStep {
        var delta: Float
        var normalizedAge: Float
    }

    private mutating func activeEmissionStep(_ dt: Float) -> ActiveEmissionStep {
        guard duration > 0 else {
            return ActiveEmissionStep(delta: dt, normalizedAge: 1)
        }
        let startAge = emitterAge
        if looping {
            emitterAge = (emitterAge + dt).truncatingRemainder(dividingBy: duration)
            let sampleAge = (startAge + dt * 0.5).truncatingRemainder(dividingBy: duration)
            return ActiveEmissionStep(delta: dt, normalizedAge: simd_clamp(sampleAge / duration, 0, 1))
        }

        let remaining = max(0, duration - emitterAge)
        let activeDelta = min(dt, remaining)
        emitterAge += dt
        let sampleAge = startAge + activeDelta * 0.5
        return ActiveEmissionStep(delta: activeDelta, normalizedAge: simd_clamp(sampleAge / duration, 0, 1))
    }

    private mutating func spawn(_ count: Int,
                                worldTransform: simd_float4x4? = nil,
                                worldOriginOverride: SIMD3<Float>? = nil,
                                inheritedWorldVelocity: SIMD3<Float> = .zero) {
        guard count > 0, maxParticles > 0 else { return }
        let room = maxParticles - particles.count
        let n = min(count, max(0, room))
        for _ in 0..<n {
            let sample = makeSpawnSample()
            let localPosition = originOffset + sample.offset
            let localVelocity = startVelocity + sample.velocityJitter
            let spawnTransform = worldTransform ?? matrix_identity_float4x4
            let inheritedVelocity = inheritedSpawnVelocity(inheritedWorldVelocity,
                                                           spawnTransform: spawnTransform)
            let position: SIMD3<Float>
            let velocity: SIMD3<Float>
            switch simulationSpace {
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
                             generation: 0)
            refreshAppearance(&p)
            particles.append(p)
        }
    }

    private mutating func makeSpawnSample() -> ParticleSpawnSample {
        let offset = spawnOffset()
        let jitter = SIMD3<Float>(nextSigned() * velocityRandomness.x,
                                  nextSigned() * velocityRandomness.y,
                                  nextSigned() * velocityRandomness.z)
        return ParticleSpawnSample(
            offset: offset,
            velocityJitter: jitter,
            lifetime: max(0.0001, lifetime + nextSigned() * lifetimeRandomness),
            sizeScale: max(0, 1 + nextSigned() * sizeRandomness),
            rotation: startRotation + nextSigned() * rotationRandomness,
            angularVelocity: angularVelocity + nextSigned() * angularVelocityRandomness
        )
    }

    private mutating func spawnSubEmitterParticles(trigger: ParticleSubEmitterTrigger,
                                                   source: Particle,
                                                   survivorsCount: Int,
                                                   pending: inout [Particle]) {
        guard maxParticles > 0 else { return }
        if let legacy = legacySubEmitterRule, legacy.trigger == trigger {
            spawnSubEmitterParticles(legacy,
                                     appearanceIndex: 1,
                                     source: source,
                                     survivorsCount: survivorsCount,
                                     pending: &pending)
        }
        for (index, rule) in subEmitters.enumerated() where rule.trigger == trigger {
            spawnSubEmitterParticles(rule,
                                     appearanceIndex: UInt16(clamping: index + 2),
                                     source: source,
                                     survivorsCount: survivorsCount,
                                     pending: &pending)
        }
    }

    private mutating func spawnSubEmitterParticles(_ rule: ParticleSubEmitter,
                                                   appearanceIndex: UInt16,
                                                   source: Particle,
                                                   survivorsCount: Int,
                                                   pending: inout [Particle]) {
        guard rule.isActive,
              source.generation < UInt8(clamping: rule.maxDepth)
        else { return }
        if rule.probability < 1, nextUnit() > rule.probability {
            return
        }

        let room = maxParticles - survivorsCount - pending.count
        guard room > 0 else { return }
        let count = min(rule.burstCount, room)
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
                                 rotation: startRotation + nextSigned() * rotationRandomness,
                                 angularVelocity: angularVelocity + nextSigned() * angularVelocityRandomness,
                                 generation: childGeneration,
                                 appearanceIndex: appearanceIndex)
            refreshAppearance(&child)
            pending.append(child)
        }
    }

    private mutating func appendEventParticles(_ eventParticles: [Particle]) {
        guard !eventParticles.isEmpty else { return }
        let room = maxParticles - particles.count
        guard room > 0 else { return }
        particles.append(contentsOf: eventParticles.prefix(room))
    }

    private mutating func spawnDistanceEmission(from previous: SIMD3<Float>?,
                                                to current: SIMD3<Float>,
                                                worldTransform: simd_float4x4?,
                                                inheritedWorldVelocity: SIMD3<Float>,
                                                rateMultiplier: Float) {
        defer { previousEmitterPosition = current }
        guard distanceEmissionRate > 0,
              rateMultiplier > 0,
              let previous else { return }
        let delta = current - previous
        let distance = simd_length(delta)
        guard distance > 0.0001 else { return }

        distanceEmissionAccumulator += distance * distanceEmissionRate * rateMultiplier
        let toSpawn = Int(distanceEmissionAccumulator)
        guard toSpawn > 0 else { return }
        distanceEmissionAccumulator -= Float(toSpawn)

        switch simulationSpace {
        case .local:
            spawn(toSpawn, worldTransform: worldTransform, inheritedWorldVelocity: inheritedWorldVelocity)
        case .world:
            for index in 0..<toSpawn {
                let t = (Float(index) + 0.5) / Float(toSpawn)
                let worldOrigin = previous + delta * t
                spawn(1,
                      worldTransform: worldTransform,
                      worldOriginOverride: worldOrigin,
                      inheritedWorldVelocity: inheritedWorldVelocity)
            }
        }
    }

    private func inheritedEmitterVelocity(from previous: SIMD3<Float>?,
                                          to current: SIMD3<Float>,
                                          deltaTime: Float) -> SIMD3<Float> {
        guard velocityInheritance > 0,
              let previous,
              deltaTime > 0.0001
        else { return .zero }
        return (current - previous) / deltaTime
    }

    private func inheritedSpawnVelocity(_ worldVelocity: SIMD3<Float>,
                                        spawnTransform: simd_float4x4) -> SIMD3<Float> {
        guard velocityInheritance > 0 else { return .zero }
        switch simulationSpace {
        case .local:
            return Self.transformDirection(worldVelocity, by: simd_inverse(spawnTransform)) * velocityInheritance
        case .world:
            return worldVelocity * velocityInheritance
        }
    }

    private func distanceEmitterPosition(worldTransform: simd_float4x4?) -> SIMD3<Float> {
        Self.transformPoint(originOffset, by: worldTransform ?? matrix_identity_float4x4)
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

    private func refreshAppearance(_ p: inout Particle) {
        let t = p.normalizedAge
        let sizeT = sizeCurve.evaluate(at: t)
        let colorT = colorCurve.evaluate(at: t)
        let appearance = appearance(for: p)
        p.size = (appearance.startSize + (appearance.endSize - appearance.startSize) * sizeT) * p.sizeScale
        p.color = appearance.startColor + (appearance.endColor - appearance.startColor) * colorT
    }

    private func appearance(for particle: Particle) -> ParticleAppearance {
        guard particle.appearanceIndex > 0 else {
            return ParticleAppearance(startSize: startSize,
                                      endSize: endSize,
                                      startColor: startColor,
                                      endColor: endColor)
        }
        if particle.appearanceIndex == 1 {
            return ParticleAppearance(startSize: subEmitterStartSize,
                                      endSize: subEmitterEndSize,
                                      startColor: subEmitterStartColor,
                                      endColor: subEmitterEndColor)
        }
        let ruleIndex = Int(particle.appearanceIndex) - 2
        if subEmitters.indices.contains(ruleIndex) {
            let rule = subEmitters[ruleIndex]
            return ParticleAppearance(startSize: rule.startSize,
                                      endSize: rule.endSize,
                                      startColor: rule.startColor,
                                      endColor: rule.endColor)
        }
        return ParticleAppearance(startSize: subEmitterStartSize,
                                  endSize: subEmitterEndSize,
                                  startColor: subEmitterStartColor,
                                  endColor: subEmitterEndColor)
    }

    private var legacySubEmitterRule: ParticleSubEmitter? {
        guard subEmitterTrigger != .none,
              subEmitterBurstCount > 0
        else { return nil }
        return ParticleSubEmitter(trigger: subEmitterTrigger,
                                  burstCount: subEmitterBurstCount,
                                  probability: subEmitterProbability,
                                  maxDepth: subEmitterMaxDepth,
                                  inheritVelocity: subEmitterInheritVelocity,
                                  lifetime: subEmitterLifetime,
                                  startVelocity: subEmitterStartVelocity,
                                  velocityRandomness: subEmitterVelocityRandomness,
                                  startSize: subEmitterStartSize,
                                  endSize: subEmitterEndSize,
                                  startColor: subEmitterStartColor,
                                  endColor: subEmitterEndColor)
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

    private func forceAcceleration(position: SIMD3<Float>) -> SIMD3<Float> {
        guard forceMode != .none, forceStrength != 0 else { return .zero }

        let offset = position - forceCenter
        let distance = simd_length(offset)
        if forceRadius > 0, distance >= forceRadius {
            return .zero
        }

        let attenuation: Float
        if forceRadius > 0 {
            attenuation = pow(max(0, 1 - distance / forceRadius), forceFalloff)
        } else {
            attenuation = 1
        }
        guard attenuation > 0 else { return .zero }

        switch forceMode {
        case .none:
            return .zero
        case .radial:
            guard distance > 0.0001 else { return .zero }
            return (offset / distance) * forceStrength * attenuation
        case .vortex:
            let axis = normalizedOrDefault(forceAxis, SIMD3<Float>(0, 1, 0))
            let planar = offset - axis * simd_dot(offset, axis)
            let planarDistance = simd_length(planar)
            guard planarDistance > 0.0001 else { return .zero }
            let radial = planar / planarDistance
            let tangent = normalizedOrDefault(simd_cross(axis, radial), SIMD3<Float>(0, 0, 1))
            return tangent * forceStrength * attenuation
        }
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

    private func applyCollision(to p: inout Particle, context: ParticleCollisionContext?) -> Bool {
        switch collisionMode {
        case .none:
            return false
        case .localPlane:
            guard p.position.y < collisionPlaneY else { return false }
            p.position.y = collisionPlaneY
            guard p.velocity.y < 0 else { return false }
            p.velocity.y = -p.velocity.y * collisionRestitution
            let tangentScale = 1 - collisionDamping
            p.velocity.x *= tangentScale
            p.velocity.z *= tangentScale
            return true
        case .worldPlane:
            let context = context ?? ParticleCollisionContext(
                toWorld: matrix_identity_float4x4,
                toLocal: matrix_identity_float4x4
            )
            let worldPosition4 = context.toWorld * SIMD4<Float>(p.position, 1)
            guard worldPosition4.y < collisionPlaneY else { return false }

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
            guard worldVelocity4.y < 0 else { return false }

            let tangentScale = 1 - collisionDamping
            let bouncedWorldVelocity = SIMD4<Float>(
                worldVelocity4.x * tangentScale,
                -worldVelocity4.y * collisionRestitution,
                worldVelocity4.z * tangentScale,
                0
            )
            let localVelocity4 = context.toLocal * bouncedWorldVelocity
            p.velocity = SIMD3<Float>(localVelocity4.x, localVelocity4.y, localVelocity4.z)
            return true
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
        let transform = worldTransform(for: entity)?.matrix
        return updateComponent(ParticleEmitter.self, for: entity) { emitter in
            emitter.emit(count, worldTransform: transform)
        }
    }
}

import EngineKernel
import SIMDCompat

public struct ParticleEvent: Sendable, Equatable {
    public var trigger: ParticleSubEmitterTrigger
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public var age: Float
    public var lifetime: Float
    public var generation: UInt8
    public var appearanceIndex: UInt16

    public init(trigger: ParticleSubEmitterTrigger,
                position: SIMD3<Float>,
                velocity: SIMD3<Float>,
                age: Float,
                lifetime: Float,
                generation: UInt8,
                appearanceIndex: UInt16) {
        self.trigger = trigger
        self.position = position
        self.velocity = velocity
        self.age = max(0, age)
        self.lifetime = max(0, lifetime)
        self.generation = generation
        self.appearanceIndex = appearanceIndex
    }

    public init(trigger: ParticleSubEmitterTrigger, source: Particle) {
        self.init(trigger: trigger,
                  position: source.position,
                  velocity: source.velocity,
                  age: source.age,
                  lifetime: source.lifetime,
                  generation: source.generation,
                  appearanceIndex: source.appearanceIndex)
    }
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

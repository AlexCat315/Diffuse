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
    public var textureFrameSeed: UInt16

    public init(position: SIMD3<Float>, velocity: SIMD3<Float>,
                age: Float = 0, lifetime: Float,
                sizeScale: Float = 1,
                rotation: Float = 0,
                angularVelocity: Float = 0,
                size: Float = 1, color: SIMD4<Float> = .init(1, 1, 1, 1),
                generation: UInt8 = 0,
                appearanceIndex: UInt16 = 0,
                textureFrameSeed: UInt16 = 0) {
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
        self.textureFrameSeed = textureFrameSeed
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

public enum ParticleSimulationBackend: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    /// CPU simulation is authoritative.
    case cpu
    /// Use GPU simulation when the emitter's authored modules are supported; otherwise fall back to CPU.
    case gpuIfSupported
    /// Require GPU simulation. Unsupported module combinations are reported by `ParticleGPUSimulationPlan`.
    case gpuRequired
}

public enum ParticleRenderBoundsMode: String, CaseIterable, Codable, Sendable, Equatable {
    /// Frustum culling is disabled for this emitter.
    case disabled
    /// Use the authored `renderBoundsRadius`.
    case manual
    /// Estimate a conservative radius from emitter shape, lifetime, velocity, forces, and billboard size.
    case automatic
}

public struct ParticleAdvanceOptions: Sendable, Equatable {
    public var emissionScale: Float
    public var burstScale: Float
    public var distanceEmissionScale: Float
    public var maxLiveParticleScale: Float

    public init(emissionScale: Float = 1,
                burstScale: Float = 1,
                distanceEmissionScale: Float = 1,
                maxLiveParticleScale: Float = 1) {
        self.emissionScale = simd_clamp(emissionScale, 0, 10)
        self.burstScale = simd_clamp(burstScale, 0, 10)
        self.distanceEmissionScale = simd_clamp(distanceEmissionScale, 0, 10)
        self.maxLiveParticleScale = simd_clamp(maxLiveParticleScale, 0, 1)
    }

    public static let `default` = ParticleAdvanceOptions()

    public func liveParticleLimit(configuredMaxParticles: Int) -> Int {
        let configured = max(0, configuredMaxParticles)
        guard configured > 0 else { return 0 }
        guard maxLiveParticleScale < 1 else { return configured }
        guard maxLiveParticleScale > 0 else { return 0 }
        return min(configured, max(1, Int(floor(Float(configured) * maxLiveParticleScale))))
    }
}

public enum ParticleBlendMode: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case alpha
    case additive
}

public enum ParticleRenderMode: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case billboard
    case ribbon
}

public enum ParticleSortMode: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    /// Transparent-safe default: farther particles are submitted first.
    case distanceDescending
    /// Nearer particles are submitted first. Useful for stylized additive effects.
    case distanceAscending
    /// Older particles are submitted first.
    case oldestFirst
    /// Younger particles are submitted first.
    case youngestFirst
}

public enum ParticleTextureSheetPlaybackMode: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    /// Preserve legacy behavior: FPS playback when frame rate is positive, otherwise lifetime mapping.
    case automatic
    /// Map the particle's normalized lifetime across the sheet once.
    case lifetime
    /// Advance by `textureSheetFrameRate` and hold the last frame.
    case playOnce
    /// Advance by `textureSheetFrameRate` and wrap inside the authored frame count.
    case loop
    /// Hold `textureSheetStartFrame`, with optional per-particle random offset.
    case singleFrame
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

public enum ParticleVectorFieldMode: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case none
    case uniform
    case curl
}

public enum ParticleSubEmitterTrigger: String, CaseIterable, Codable, Sendable, Equatable, Hashable {
    case none
    case death
    case collision
}

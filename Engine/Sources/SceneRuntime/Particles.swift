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

public enum ParticleGPUSimulationPlanStatus: String, Codable, Sendable, Equatable, Hashable {
    case disabled
    case supported
    case fallbackToCPU
    case requiredButUnsupported
}

public enum ParticleGPUSimulationUnsupportedReason: String, Codable, Sendable, Equatable, Hashable {
    case backendCPU
    case noParticleCapacity
    case eventSubEmitters
    case distanceEmission
    case noise
    case forceFields
    case collisions
    case angularVelocity
}

public struct ParticleGPUSimulationPlan: Sendable, Equatable {
    public static let maximumWorkgroupSize = 256

    public var backend: ParticleSimulationBackend
    public var status: ParticleGPUSimulationPlanStatus
    public var particleCapacity: Int
    public var workgroupSize: Int
    public var dispatchWorkgroups: Int
    public var unsupportedReasons: [ParticleGPUSimulationUnsupportedReason]

    public init(emitter: ParticleEmitter) {
        self.backend = emitter.simulationBackend
        self.particleCapacity = max(0, emitter.maxParticles)
        self.workgroupSize = min(
            max(1, emitter.gpuSimulationWorkgroupSize),
            Self.maximumWorkgroupSize
        )
        self.dispatchWorkgroups = particleCapacity > 0
            ? Int(ceil(Float(particleCapacity) / Float(workgroupSize)))
            : 0

        var reasons: [ParticleGPUSimulationUnsupportedReason] = []
        if emitter.simulationBackend == .cpu {
            reasons.append(.backendCPU)
        }
        if particleCapacity == 0 {
            reasons.append(.noParticleCapacity)
        }
        if emitter.distanceEmissionRate > 0 {
            reasons.append(.distanceEmission)
        }
        self.unsupportedReasons = reasons

        if emitter.simulationBackend == .cpu {
            self.status = .disabled
        } else if reasons.isEmpty {
            self.status = .supported
        } else if emitter.simulationBackend == .gpuRequired {
            self.status = .requiredButUnsupported
        } else {
            self.status = .fallbackToCPU
        }
    }

    public var usesGPU: Bool {
        status == .supported
    }
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

public struct ParticleScalabilityResource: Sendable, Equatable {
    public var emissionScale: Float
    public var burstScale: Float
    public var distanceEmissionScale: Float
    public var maxLiveParticleScale: Float

    public init(emissionScale: Float = 1,
                burstScale: Float = 1,
                distanceEmissionScale: Float = 1,
                maxLiveParticleScale: Float = 1) {
        let options = ParticleAdvanceOptions(emissionScale: emissionScale,
                                             burstScale: burstScale,
                                             distanceEmissionScale: distanceEmissionScale,
                                             maxLiveParticleScale: maxLiveParticleScale)
        self.emissionScale = options.emissionScale
        self.burstScale = options.burstScale
        self.distanceEmissionScale = options.distanceEmissionScale
        self.maxLiveParticleScale = options.maxLiveParticleScale
    }

    public static let `default` = ParticleScalabilityResource()

    public var advanceOptions: ParticleAdvanceOptions {
        ParticleAdvanceOptions(emissionScale: emissionScale,
                               burstScale: burstScale,
                               distanceEmissionScale: distanceEmissionScale,
                               maxLiveParticleScale: maxLiveParticleScale)
    }
}

public enum ParticleScalabilityPressureReason: String, CaseIterable, Sendable, Equatable {
    case none
    case liveBudget
    case spawnBudget
    case capacityLimited
}

public struct ParticleScalabilityStateResource: Sendable, Equatable {
    public var appliedScale: Float
    public var pressure: Float
    public var reason: ParticleScalabilityPressureReason

    public init(appliedScale: Float = 1,
                pressure: Float = 0,
                reason: ParticleScalabilityPressureReason = .none) {
        self.appliedScale = simd_clamp(appliedScale, 0, 1)
        self.pressure = simd_clamp(pressure, 0, 10)
        self.reason = reason
    }

    public static let `default` = ParticleScalabilityStateResource()

    public func applying(to base: ParticleAdvanceOptions) -> ParticleAdvanceOptions {
        ParticleAdvanceOptions(emissionScale: base.emissionScale * appliedScale,
                               burstScale: base.burstScale * appliedScale,
                               distanceEmissionScale: base.distanceEmissionScale * appliedScale,
                               maxLiveParticleScale: base.maxLiveParticleScale * appliedScale)
    }
}

public struct ParticleScalabilityPolicyResource: Sendable, Equatable {
    public var isEnabled: Bool
    public var targetLiveParticles: Int
    public var targetSpawnedParticlesPerFrame: Int
    public var minimumScale: Float
    public var pressureStep: Float
    public var recoveryStep: Float

    public init(isEnabled: Bool = false,
                targetLiveParticles: Int = 0,
                targetSpawnedParticlesPerFrame: Int = 0,
                minimumScale: Float = 0.25,
                pressureStep: Float = 0.15,
                recoveryStep: Float = 0.05) {
        self.isEnabled = isEnabled
        self.targetLiveParticles = max(0, targetLiveParticles)
        self.targetSpawnedParticlesPerFrame = max(0, targetSpawnedParticlesPerFrame)
        self.minimumScale = simd_clamp(minimumScale, 0, 1)
        self.pressureStep = simd_clamp(pressureStep, 0, 1)
        self.recoveryStep = simd_clamp(recoveryStep, 0, 1)
    }

    public static let disabled = ParticleScalabilityPolicyResource()

    public func updatedState(previousStats: ParticleFrameStatsResource,
                             previousState: ParticleScalabilityStateResource = .default)
        -> ParticleScalabilityStateResource {
        guard isEnabled else { return .default }

        let pressureSample = pressure(from: previousStats)
        let nextScale: Float
        if pressureSample.pressure > 0 {
            let reduction = pressureStep * min(1, pressureSample.pressure)
            nextScale = max(minimumScale, previousState.appliedScale * (1 - reduction))
        } else {
            nextScale = min(1, previousState.appliedScale + recoveryStep)
        }
        return ParticleScalabilityStateResource(appliedScale: nextScale,
                                                pressure: pressureSample.pressure,
                                                reason: pressureSample.reason)
    }

    private func pressure(from stats: ParticleFrameStatsResource)
        -> (pressure: Float, reason: ParticleScalabilityPressureReason) {
        if stats.capacityLimitedSpawnCount > 0 {
            return (1, .capacityLimited)
        }

        var pressure: Float = 0
        var reason: ParticleScalabilityPressureReason = .none
        if targetLiveParticles > 0, stats.liveParticleCount > targetLiveParticles {
            pressure = max(pressure, Float(stats.liveParticleCount - targetLiveParticles)
                           / Float(targetLiveParticles))
            reason = .liveBudget
        }
        if targetSpawnedParticlesPerFrame > 0,
           stats.spawnedParticleCount > targetSpawnedParticlesPerFrame {
            let spawnPressure = Float(stats.spawnedParticleCount - targetSpawnedParticlesPerFrame)
                / Float(targetSpawnedParticlesPerFrame)
            if spawnPressure > pressure {
                pressure = spawnPressure
                reason = .spawnBudget
            }
        }
        return (pressure, reason)
    }
}

public struct ParticleEmitterFrameStats: Sendable, Equatable {
    public var simulatedDeltaTime: Float
    public var startingLiveParticleCount: Int
    public var liveParticleCount: Int
    public var maxParticleCount: Int
    public var liveParticleLimit: Int
    public var continuousSpawnedCount: Int
    public var burstSpawnedCount: Int
    public var distanceSpawnedCount: Int
    public var subEmitterSpawnedCount: Int
    public var expiredParticleCount: Int
    public var collisionCount: Int
    public var capacityLimitedSpawnCount: Int

    public init(simulatedDeltaTime: Float = 0,
                startingLiveParticleCount: Int = 0,
                liveParticleCount: Int = 0,
                maxParticleCount: Int = 0,
                liveParticleLimit: Int = 0,
                continuousSpawnedCount: Int = 0,
                burstSpawnedCount: Int = 0,
                distanceSpawnedCount: Int = 0,
                subEmitterSpawnedCount: Int = 0,
                expiredParticleCount: Int = 0,
                collisionCount: Int = 0,
                capacityLimitedSpawnCount: Int = 0) {
        self.simulatedDeltaTime = max(0, simulatedDeltaTime)
        self.startingLiveParticleCount = max(0, startingLiveParticleCount)
        self.liveParticleCount = max(0, liveParticleCount)
        self.maxParticleCount = max(0, maxParticleCount)
        self.liveParticleLimit = max(0, liveParticleLimit)
        self.continuousSpawnedCount = max(0, continuousSpawnedCount)
        self.burstSpawnedCount = max(0, burstSpawnedCount)
        self.distanceSpawnedCount = max(0, distanceSpawnedCount)
        self.subEmitterSpawnedCount = max(0, subEmitterSpawnedCount)
        self.expiredParticleCount = max(0, expiredParticleCount)
        self.collisionCount = max(0, collisionCount)
        self.capacityLimitedSpawnCount = max(0, capacityLimitedSpawnCount)
    }

    public static let empty = ParticleEmitterFrameStats()

    public var spawnedParticleCount: Int {
        continuousSpawnedCount + burstSpawnedCount + distanceSpawnedCount + subEmitterSpawnedCount
    }
}

public struct ParticleFrameStatsResource: Sendable, Equatable {
    public var simulatedDeltaTime: Float
    public var emitterCount: Int
    public var activeEmitterCount: Int
    public var liveParticleCount: Int
    public var maxParticleCount: Int
    public var liveParticleLimit: Int
    public var spawnedParticleCount: Int
    public var continuousSpawnedCount: Int
    public var burstSpawnedCount: Int
    public var distanceSpawnedCount: Int
    public var subEmitterSpawnedCount: Int
    public var expiredParticleCount: Int
    public var collisionCount: Int
    public var capacityLimitedSpawnCount: Int

    public init(simulatedDeltaTime: Float = 0,
                emitterStats: [ParticleEmitterFrameStats] = []) {
        self.simulatedDeltaTime = max(0, simulatedDeltaTime)
        self.emitterCount = emitterStats.count
        self.activeEmitterCount = emitterStats.filter {
            $0.liveParticleCount > 0 || $0.spawnedParticleCount > 0
        }.count
        self.liveParticleCount = emitterStats.reduce(0) { $0 + $1.liveParticleCount }
        self.maxParticleCount = emitterStats.reduce(0) { $0 + $1.maxParticleCount }
        self.liveParticleLimit = emitterStats.reduce(0) { $0 + $1.liveParticleLimit }
        self.spawnedParticleCount = emitterStats.reduce(0) { $0 + $1.spawnedParticleCount }
        self.continuousSpawnedCount = emitterStats.reduce(0) { $0 + $1.continuousSpawnedCount }
        self.burstSpawnedCount = emitterStats.reduce(0) { $0 + $1.burstSpawnedCount }
        self.distanceSpawnedCount = emitterStats.reduce(0) { $0 + $1.distanceSpawnedCount }
        self.subEmitterSpawnedCount = emitterStats.reduce(0) { $0 + $1.subEmitterSpawnedCount }
        self.expiredParticleCount = emitterStats.reduce(0) { $0 + $1.expiredParticleCount }
        self.collisionCount = emitterStats.reduce(0) { $0 + $1.collisionCount }
        self.capacityLimitedSpawnCount = emitterStats.reduce(0) { $0 + $1.capacityLimitedSpawnCount }
    }

    public static let empty = ParticleFrameStatsResource()
}

public struct ParticleSimulationEventApplyReport: Sendable, Equatable {
    public var requestedEmitterCount: Int
    public var appliedEmitterCount: Int
    public var missingEmitterCount: Int
    public var emptyEventEmitterCount: Int
    public var eventCount: Int
    public var appliedEventCount: Int
    public var totalReadbackEventCount: Int
    public var droppedReadbackEventCount: Int
    public var collisionEventCount: Int
    public var deathEventCount: Int
    public var subEmitterSpawnedCount: Int
    public var spawnedParticleCount: Int
    public var capacityLimitedSpawnCount: Int

    public init(requestedEmitterCount: Int = 0,
                appliedEmitterCount: Int = 0,
                missingEmitterCount: Int = 0,
                emptyEventEmitterCount: Int = 0,
                eventCount: Int = 0,
                appliedEventCount: Int = 0,
                totalReadbackEventCount: Int = 0,
                droppedReadbackEventCount: Int = 0,
                collisionEventCount: Int = 0,
                deathEventCount: Int = 0,
                subEmitterSpawnedCount: Int = 0,
                spawnedParticleCount: Int = 0,
                capacityLimitedSpawnCount: Int = 0) {
        self.requestedEmitterCount = max(0, requestedEmitterCount)
        self.appliedEmitterCount = max(0, appliedEmitterCount)
        self.missingEmitterCount = max(0, missingEmitterCount)
        self.emptyEventEmitterCount = max(0, emptyEventEmitterCount)
        self.eventCount = max(0, eventCount)
        self.appliedEventCount = max(0, appliedEventCount)
        self.totalReadbackEventCount = max(0, totalReadbackEventCount)
        self.droppedReadbackEventCount = max(0, droppedReadbackEventCount)
        self.collisionEventCount = max(0, collisionEventCount)
        self.deathEventCount = max(0, deathEventCount)
        self.subEmitterSpawnedCount = max(0, subEmitterSpawnedCount)
        self.spawnedParticleCount = max(0, spawnedParticleCount)
        self.capacityLimitedSpawnCount = max(0, capacityLimitedSpawnCount)
    }

    public static let empty = ParticleSimulationEventApplyReport()
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
    /// Maximum source particles submitted to the renderer per frame. Zero renders the whole live pool.
    public var maxRenderedParticles: Int
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
    /// Optional CPU vector field module. This is deterministic and can later be mirrored by GPU simulation.
    public var vectorFieldMode: ParticleVectorFieldMode
    /// Preferred direction for uniform vector fields and the curl-field bias axis.
    public var vectorFieldDirection: SIMD3<Float>
    /// Acceleration magnitude contributed by the vector field.
    public var vectorFieldStrength: Float
    /// Spatial frequency for procedural vector-field sampling.
    public var vectorFieldScale: Float
    /// Lifetime-time scroll speed for procedural vector-field sampling.
    public var vectorFieldScrollSpeed: Float
    public var collisionMode: ParticleCollisionMode
    public var simulationSpace: ParticleSimulationSpace
    /// Selects the authoritative particle simulation backend. GPU modes currently expose
    /// planning/validation and prepare the emitter for a compute-dispatch path.
    public var simulationBackend: ParticleSimulationBackend
    /// Number of particles handled per compute workgroup when GPU simulation is active.
    public var gpuSimulationWorkgroupSize: Int
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
    public var renderMode: ParticleRenderMode
    /// Controls CPU render submission ordering for transparent particle pools.
    public var sortMode: ParticleSortMode
    /// Multiplier applied to the generated ribbon width. One keeps particle size as width.
    public var ribbonWidthScale: Float
    /// Width multiplier at the oldest ribbon end. One keeps a constant-width ribbon.
    public var ribbonTailWidthScale: Float
    /// Alpha multiplier at the oldest ribbon end. One keeps opacity unchanged along the ribbon.
    public var ribbonTailAlphaScale: Float
    /// Maximum allowed distance between connected ribbon particles. Zero disables gap breaking.
    public var ribbonMaxSegmentLength: Float
    /// Overlap added at connected ribbon joins as a multiple of segment width.
    /// This masks corner cracks while ribbons are still rendered as one quad per segment.
    public var ribbonJoinOverlapScale: Float
    /// Number of render segments generated per connected particle pair. One preserves the raw polyline.
    public var ribbonSmoothingSegments: Int
    /// Texture repeats per world unit along the ribbon. Zero uses one full V range per segment.
    public var ribbonTextureTiling: Float
    /// Base V offset applied before ribbon texture tiling.
    public var ribbonTextureOffset: Float
    public var renderAlignment: ParticleRenderAlignment
    /// Additional length per unit of particle speed when `renderAlignment == .velocity`.
    public var velocityStretchScale: Float
    /// Upper bound for velocity-aligned stretch.
    public var velocityStretchMax: Float
    /// Maximum camera distance at which this emitter contributes render particles. Zero disables distance culling.
    public var maxRenderDistance: Float
    /// Range before `maxRenderDistance` over which rendered alpha fades to zero.
    public var renderDistanceFadeRange: Float
    /// Camera distance where render LOD scaling begins. Disabled unless end distance is greater than start distance.
    public var renderLODStartDistance: Float
    /// Camera distance where render LOD reaches `renderLODMinParticleScale`.
    public var renderLODEndDistance: Float
    /// Minimum fraction of the render particle submission budget kept at `renderLODEndDistance`.
    public var renderLODMinParticleScale: Float
    /// Chooses whether camera-frustum culling uses no bounds, manual bounds, or an estimated conservative bound.
    public var renderBoundsMode: ParticleRenderBoundsMode
    /// World-space radius around `originOffset` used when `renderBoundsMode == .manual`.
    public var renderBoundsRadius: Float
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
    /// Controls how the texture sheet frame is selected over particle lifetime.
    public var textureSheetPlaybackMode: ParticleTextureSheetPlaybackMode
    /// First frame used by texture sheet playback.
    public var textureSheetStartFrame: Int
    /// Additional stable per-particle random frame offset in frames.
    public var textureSheetFrameRandomness: Int
    /// Optional authored module stack metadata. Runtime simulation still reads the
    /// concrete emitter fields, while editor tooling uses this to preserve module
    /// order and enabled states.
    public var authoredModuleStack: ParticleModuleStack?
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
    public private(set) var lastFrameSpawnedParticles: [Particle]
    public private(set) var lastFrameEvents: [ParticleEvent]
    public private(set) var lastFrameStats: ParticleEmitterFrameStats
    private var emitterAge: Float
    private var emissionAccumulator: Float
    private var distanceEmissionAccumulator: Float
    private var burstAccumulator: Float
    private var burstSpawnAccumulator: Float
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
        maxRenderedParticles: Int = 0,
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
        vectorFieldMode: ParticleVectorFieldMode = .none,
        vectorFieldDirection: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        vectorFieldStrength: Float = 0,
        vectorFieldScale: Float = 1,
        vectorFieldScrollSpeed: Float = 0,
        collisionMode: ParticleCollisionMode = .none,
        simulationSpace: ParticleSimulationSpace = .local,
        simulationBackend: ParticleSimulationBackend = .cpu,
        gpuSimulationWorkgroupSize: Int = 64,
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
        renderMode: ParticleRenderMode = .billboard,
        sortMode: ParticleSortMode = .distanceDescending,
        ribbonWidthScale: Float = 1,
        ribbonTailWidthScale: Float = 1,
        ribbonTailAlphaScale: Float = 1,
        ribbonMaxSegmentLength: Float = 0,
        ribbonJoinOverlapScale: Float = 0,
        ribbonSmoothingSegments: Int = 1,
        ribbonTextureTiling: Float = 0,
        ribbonTextureOffset: Float = 0,
        renderAlignment: ParticleRenderAlignment = .billboard,
        velocityStretchScale: Float = 0,
        velocityStretchMax: Float = 8,
        maxRenderDistance: Float = 0,
        renderDistanceFadeRange: Float = 0,
        renderLODStartDistance: Float = 0,
        renderLODEndDistance: Float = 0,
        renderLODMinParticleScale: Float = 1,
        renderBoundsMode: ParticleRenderBoundsMode? = nil,
        renderBoundsRadius: Float = 0,
        textureAssetID: String? = nil,
        texturePath: String? = nil,
        textureSheetColumns: Int = 1,
        textureSheetRows: Int = 1,
        textureSheetFrameCount: Int = 1,
        textureSheetFrameRate: Float = 0,
        textureSheetPlaybackMode: ParticleTextureSheetPlaybackMode = .automatic,
        textureSheetStartFrame: Int = 0,
        textureSheetFrameRandomness: Int = 0,
        authoredModuleStack: ParticleModuleStack? = nil,
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
        self.maxRenderedParticles = max(0, maxRenderedParticles)
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
        self.vectorFieldMode = vectorFieldMode
        self.vectorFieldDirection = vectorFieldDirection
        self.vectorFieldStrength = vectorFieldStrength
        self.vectorFieldScale = max(0.0001, vectorFieldScale)
        self.vectorFieldScrollSpeed = max(0, vectorFieldScrollSpeed)
        self.collisionMode = collisionMode
        self.simulationSpace = simulationSpace
        self.simulationBackend = simulationBackend
        self.gpuSimulationWorkgroupSize = max(1, gpuSimulationWorkgroupSize)
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
        self.renderMode = renderMode
        self.sortMode = sortMode
        self.ribbonWidthScale = max(0, ribbonWidthScale)
        self.ribbonTailWidthScale = max(0, ribbonTailWidthScale)
        self.ribbonTailAlphaScale = simd_clamp(ribbonTailAlphaScale, 0, 1)
        self.ribbonMaxSegmentLength = max(0, ribbonMaxSegmentLength)
        self.ribbonJoinOverlapScale = max(0, ribbonJoinOverlapScale)
        self.ribbonSmoothingSegments = min(16, max(1, ribbonSmoothingSegments))
        self.ribbonTextureTiling = max(0, ribbonTextureTiling)
        self.ribbonTextureOffset = ribbonTextureOffset
        self.renderAlignment = renderAlignment
        self.velocityStretchScale = max(0, velocityStretchScale)
        self.velocityStretchMax = max(1, velocityStretchMax)
        self.maxRenderDistance = max(0, maxRenderDistance)
        self.renderDistanceFadeRange = max(0, renderDistanceFadeRange)
        self.renderLODStartDistance = max(0, renderLODStartDistance)
        self.renderLODEndDistance = max(0, renderLODEndDistance)
        self.renderLODMinParticleScale = simd_clamp(renderLODMinParticleScale, 0, 1)
        self.renderBoundsMode = renderBoundsMode ?? (renderBoundsRadius > 0 ? .manual : .disabled)
        self.renderBoundsRadius = max(0, renderBoundsRadius)
        self.textureAssetID = textureAssetID?.isEmpty == true ? nil : textureAssetID
        self.texturePath = texturePath?.isEmpty == true ? nil : texturePath
        self.textureSheetColumns = max(1, textureSheetColumns)
        self.textureSheetRows = max(1, textureSheetRows)
        self.textureSheetFrameCount = max(1, textureSheetFrameCount)
        self.textureSheetFrameRate = max(0, textureSheetFrameRate)
        self.textureSheetPlaybackMode = textureSheetPlaybackMode
        self.textureSheetStartFrame = max(0, textureSheetStartFrame)
        self.textureSheetFrameRandomness = max(0, textureSheetFrameRandomness)
        self.authoredModuleStack = authoredModuleStack
        self.trailLength = max(0, trailLength)
        self.trailSegments = max(0, trailSegments)
        self.trailEndSizeScale = max(0, trailEndSizeScale)
        self.trailEndAlphaScale = simd_clamp(trailEndAlphaScale, 0, 1)
        self.seed = seed
        self.particles = []
        self.lastFrameSpawnedParticles = []
        self.lastFrameEvents = []
        self.lastFrameStats = .empty
        self.emitterAge = 0
        self.emissionAccumulator = 0
        self.distanceEmissionAccumulator = 0
        self.burstAccumulator = 0
        self.burstSpawnAccumulator = 0
        self.previousEmitterPosition = nil
        self.hasPrewarmed = false
        self.rngState = seed
    }

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

    private func estimatedBillboardRadius(velocityMagnitude: Float) -> Float {
        var size = max(startSize, endSize, subEmitterStartSize, subEmitterEndSize)
        for rule in subEmitters {
            size = max(size, rule.startSize, rule.endSize)
        }
        let sizeScale = max(0, 1 + sizeRandomness)
        let stretch = renderAlignment == .velocity
            ? min(velocityStretchMax, max(1, 1 + velocityMagnitude * velocityStretchScale))
            : 1
        let billboardRadius = max(0, size) * sizeScale * max(1, stretch) * 0.70710678
        let trailRadius = trailLength > 0 ? velocityMagnitude * trailLength : 0
        return billboardRadius + trailRadius
    }

    /// Number of currently-alive particles.
    public var aliveCount: Int { particles.count }

    public var gpuSimulationPlan: ParticleGPUSimulationPlan {
        ParticleGPUSimulationPlan(emitter: self)
    }

    /// UV rect for a particle's current texture sheet frame: x, y, width, height.
    public func textureUVRect(for particle: Particle) -> SIMD4<Float> {
        let columns = max(1, textureSheetColumns)
        let rows = max(1, textureSheetRows)
        let maxFrames = max(1, columns * rows)
        let frameIndex = textureSheetFrameIndex(for: particle, maxFrames: maxFrames)
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

    public func textureSheetFrameIndex(for particle: Particle) -> Int {
        let columns = max(1, textureSheetColumns)
        let rows = max(1, textureSheetRows)
        return textureSheetFrameIndex(for: particle, maxFrames: max(1, columns * rows))
    }

    private func textureSheetFrameIndex(for particle: Particle, maxFrames: Int) -> Int {
        let safeMaxFrames = max(1, maxFrames)
        let startFrame = min(max(0, textureSheetStartFrame), safeMaxFrames - 1)
        let safeFrameCount = min(max(1, textureSheetFrameCount), safeMaxFrames - startFrame)
        let randomRange = max(0, min(textureSheetFrameRandomness, safeFrameCount - 1))
        let randomOffset = randomRange > 0
            ? Int(particle.textureFrameSeed % UInt16(randomRange + 1))
            : 0
        let firstFrame = min(safeFrameCount - 1, randomOffset)

        let advancedFrame: Int
        switch textureSheetPlaybackMode {
        case .automatic:
            if textureSheetFrameRate > 0 {
                advancedFrame = Int(floor(max(0, particle.age) * textureSheetFrameRate))
            } else {
                advancedFrame = Int(floor(particle.normalizedAge * Float(safeFrameCount)))
            }
        case .lifetime:
            advancedFrame = Int(floor(particle.normalizedAge * Float(safeFrameCount)))
        case .playOnce:
            let rate = textureSheetFrameRate > 0 ? textureSheetFrameRate : Float(safeFrameCount)
            advancedFrame = Int(floor(max(0, particle.age) * rate))
        case .loop:
            let rate = textureSheetFrameRate > 0 ? textureSheetFrameRate : Float(safeFrameCount)
            advancedFrame = Int(floor(max(0, particle.age) * rate)) % safeFrameCount
        case .singleFrame:
            advancedFrame = 0
        }

        switch textureSheetPlaybackMode {
        case .loop:
            return startFrame + ((firstFrame + max(0, advancedFrame)) % safeFrameCount)
        case .singleFrame:
            return startFrame + firstFrame
        case .automatic, .lifetime, .playOnce:
            return startFrame + min(safeFrameCount - 1, firstFrame + max(0, advancedFrame))
        }
    }

    /// Advances the simulation by `deltaTime` seconds: integrates existing particles, culls
    /// expired ones, then spawns from the continuous emission rate and scheduled bursts
    /// (capped at `maxParticles`).
    public mutating func advance(deltaTime: Double,
                                 worldTransform: simd_float4x4? = nil,
                                 options: ParticleAdvanceOptions = .default) {
        guard deltaTime > 0 else { return }
        runPrewarmIfNeeded(worldTransform: worldTransform, options: options)
        advanceStep(deltaTime: Float(deltaTime), worldTransform: worldTransform, options: options)
    }

    private mutating func advanceStep(deltaTime dt: Float,
                                      worldTransform: simd_float4x4? = nil,
                                      options: ParticleAdvanceOptions = .default) {
        guard dt > 0 else { return }
        lastFrameSpawnedParticles.removeAll(keepingCapacity: true)
        lastFrameEvents.removeAll(keepingCapacity: true)
        let liveParticleLimit = options.liveParticleLimit(configuredMaxParticles: maxParticles)
        var frameStats = ParticleEmitterFrameStats(
            simulatedDeltaTime: dt,
            startingLiveParticleCount: particles.count,
            liveParticleCount: particles.count,
            maxParticleCount: maxParticles,
            liveParticleLimit: liveParticleLimit
        )
        let currentEmitterPosition = distanceEmitterPosition(worldTransform: worldTransform)
        let inheritedWorldVelocity = inheritedEmitterVelocity(
            from: previousEmitterPosition,
            to: currentEmitterPosition,
            deltaTime: dt
        )
        let collisionContext = simulationSpace == .local
            ? makeCollisionContext(worldTransform: worldTransform)
            : nil
        let defersEventSubEmittersToExternalSimulation = hasEventSubEmitterRules
            && gpuSimulationPlan.usesGPU

        var survivors: [Particle] = []
        var eventParticles: [Particle] = []
        var eventSubEmitterSpawnResult = ParticleSpawnResult(requested: 0, spawned: 0)
        survivors.reserveCapacity(particles.count)
        for var p in particles {
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
                                                 pending: &eventParticles)
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
                                                 pending: &eventParticles)
                    )
                }
            }
        }
        particles = survivors
        let eventSpawnResult = appendEventParticles(eventParticles)
        frameStats.subEmitterSpawnedCount += eventSpawnResult.spawned
        frameStats.capacityLimitedSpawnCount += eventSubEmitterSpawnResult.dropped + eventSpawnResult.dropped

        guard isEmitting else {
            previousEmitterPosition = currentEmitterPosition
            frameStats.liveParticleCount = particles.count
            lastFrameStats = frameStats
            return
        }
        let emissionStep = activeEmissionStep(dt)
        guard emissionStep.delta > 0 else {
            previousEmitterPosition = currentEmitterPosition
            frameStats.liveParticleCount = particles.count
            lastFrameStats = frameStats
            return
        }
        let emissionRateMultiplier = max(0, emissionRateCurve.evaluate(at: emissionStep.normalizedAge))
        let scaledEmissionRateMultiplier = emissionRateMultiplier * options.emissionScale
        if emissionRate > 0, scaledEmissionRateMultiplier > 0 {
            emissionAccumulator += emissionRate * scaledEmissionRateMultiplier * emissionStep.delta
            let toSpawn = Int(emissionAccumulator)
            if toSpawn > 0 {
                emissionAccumulator -= Float(toSpawn)
                let spawnResult = spawn(toSpawn,
                                        worldTransform: worldTransform,
                                        inheritedWorldVelocity: inheritedWorldVelocity,
                                        maxLiveParticles: liveParticleLimit)
                frameStats.continuousSpawnedCount += spawnResult.spawned
                frameStats.capacityLimitedSpawnCount += spawnResult.dropped
            }
        }
        if burstCount > 0, burstInterval > 0 {
            burstAccumulator += emissionStep.delta
            let bursts = Int(burstAccumulator / burstInterval)
            if bursts > 0 {
                burstAccumulator -= Float(bursts) * burstInterval
                burstSpawnAccumulator += Float(bursts * burstCount) * options.burstScale
                let toSpawn = Int(burstSpawnAccumulator)
                if toSpawn > 0 {
                    burstSpawnAccumulator -= Float(toSpawn)
                    let spawnResult = spawn(toSpawn,
                                            worldTransform: worldTransform,
                                            inheritedWorldVelocity: inheritedWorldVelocity,
                                            maxLiveParticles: liveParticleLimit)
                    frameStats.burstSpawnedCount += spawnResult.spawned
                    frameStats.capacityLimitedSpawnCount += spawnResult.dropped
                }
            }
        }
        let distanceRateMultiplier = max(0, distanceEmissionRateCurve.evaluate(at: emissionStep.normalizedAge))
        let distanceSpawnResult = spawnDistanceEmission(
            from: previousEmitterPosition,
            to: currentEmitterPosition,
            worldTransform: worldTransform,
            inheritedWorldVelocity: inheritedWorldVelocity,
            rateMultiplier: distanceRateMultiplier * options.distanceEmissionScale,
            maxLiveParticles: liveParticleLimit
        )
        frameStats.distanceSpawnedCount += distanceSpawnResult.spawned
        frameStats.capacityLimitedSpawnCount += distanceSpawnResult.dropped
        frameStats.liveParticleCount = particles.count
        lastFrameStats = frameStats
    }

    /// Spawns `count` particles immediately (a burst), independent of the emission rate.
    /// Honors the `maxParticles` cap.
    public mutating func emit(_ count: Int, worldTransform: simd_float4x4? = nil) {
        spawn(count, worldTransform: worldTransform, recordSpawned: false)
    }

    /// Removes all live particles and resets emission timing.
    public mutating func clear() {
        particles.removeAll(keepingCapacity: true)
        emitterAge = 0
        emissionAccumulator = 0
        distanceEmissionAccumulator = 0
        burstAccumulator = 0
        burstSpawnAccumulator = 0
        previousEmitterPosition = nil
        hasPrewarmed = false
        lastFrameSpawnedParticles.removeAll(keepingCapacity: true)
        lastFrameEvents.removeAll(keepingCapacity: true)
        lastFrameStats = .empty
    }

    /// Applies collision/death events produced by an external simulation backend and spawns
    /// matching sub-emitter particles through the same rules as CPU simulation.
    @discardableResult
    public mutating func applySimulationEvents(_ events: [ParticleEvent]) -> ParticleEmitterFrameStats {
        lastFrameSpawnedParticles.removeAll(keepingCapacity: true)
        lastFrameEvents.removeAll(keepingCapacity: true)
        var frameStats = ParticleEmitterFrameStats(
            startingLiveParticleCount: particles.count,
            liveParticleCount: particles.count,
            maxParticleCount: maxParticles,
            liveParticleLimit: maxParticles
        )
        guard !events.isEmpty else {
            lastFrameStats = frameStats
            return frameStats
        }

        var eventParticles: [Particle] = []
        var eventSubEmitterSpawnResult = ParticleSpawnResult(requested: 0, spawned: 0)
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
                                         survivorsCount: particles.count,
                                         pending: &eventParticles)
            )
        }

        let eventSpawnResult = appendEventParticles(eventParticles)
        frameStats.subEmitterSpawnedCount += eventSpawnResult.spawned
        frameStats.capacityLimitedSpawnCount += eventSubEmitterSpawnResult.dropped + eventSpawnResult.dropped
        frameStats.liveParticleCount = particles.count
        lastFrameStats = frameStats
        return frameStats
    }

    // MARK: - Internals

    private struct ParticleSpawnResult {
        var requested: Int
        var spawned: Int

        var dropped: Int {
            max(0, requested - spawned)
        }

        mutating func include(_ other: ParticleSpawnResult) {
            requested += other.requested
            spawned += other.spawned
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

    private struct ParticleAppearance {
        var startSize: Float
        var endSize: Float
        var startColor: SIMD4<Float>
        var endColor: SIMD4<Float>
    }

    private mutating func recordEvent(trigger: ParticleSubEmitterTrigger,
                                      source: Particle) {
        guard trigger != .none else { return }
        lastFrameEvents.append(ParticleEvent(trigger: trigger, source: source))
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
            advanceStep(deltaTime: dt, worldTransform: worldTransform, options: options)
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

    @discardableResult
    private mutating func spawn(_ count: Int,
                                worldTransform: simd_float4x4? = nil,
                                worldOriginOverride: SIMD3<Float>? = nil,
                                inheritedWorldVelocity: SIMD3<Float> = .zero,
                                maxLiveParticles: Int? = nil,
                                recordSpawned: Bool = true) -> ParticleSpawnResult {
        let requested = max(0, count)
        guard requested > 0, maxParticles > 0 else {
            return ParticleSpawnResult(requested: requested, spawned: 0)
        }
        let liveLimit = min(maxParticles, max(0, maxLiveParticles ?? maxParticles))
        let room = liveLimit - particles.count
        let n = min(requested, max(0, room))
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
                             generation: 0,
                             textureFrameSeed: sample.textureFrameSeed)
            refreshAppearance(&p)
            particles.append(p)
            if recordSpawned {
                lastFrameSpawnedParticles.append(p)
            }
        }
        return ParticleSpawnResult(requested: requested, spawned: n)
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
            angularVelocity: angularVelocity + nextSigned() * angularVelocityRandomness,
            textureFrameSeed: textureFrameSeedSnapshot()
        )
    }

    private mutating func spawnSubEmitterParticles(trigger: ParticleSubEmitterTrigger,
                                                   source: Particle,
                                                   survivorsCount: Int,
                                                   pending: inout [Particle]) -> ParticleSpawnResult {
        guard maxParticles > 0 else {
            return ParticleSpawnResult(requested: 0, spawned: 0)
        }
        var result = ParticleSpawnResult(requested: 0, spawned: 0)
        if let legacy = legacySubEmitterRule, legacy.trigger == trigger {
            result.include(
                spawnSubEmitterParticles(legacy,
                                         appearanceIndex: 1,
                                         source: source,
                                         survivorsCount: survivorsCount,
                                         pending: &pending)
            )
        }
        for (index, rule) in subEmitters.enumerated() where rule.trigger == trigger {
            result.include(
                spawnSubEmitterParticles(rule,
                                         appearanceIndex: UInt16(clamping: index + 2),
                                         source: source,
                                         survivorsCount: survivorsCount,
                                         pending: &pending)
            )
        }
        return result
    }

    private mutating func spawnSubEmitterParticles(_ rule: ParticleSubEmitter,
                                                   appearanceIndex: UInt16,
                                                   source: Particle,
                                                   survivorsCount: Int,
                                                   pending: inout [Particle]) -> ParticleSpawnResult {
        guard rule.isActive,
              source.generation < UInt8(clamping: rule.maxDepth)
        else { return ParticleSpawnResult(requested: 0, spawned: 0) }
        if rule.probability < 1, nextUnit() > rule.probability {
            return ParticleSpawnResult(requested: 0, spawned: 0)
        }

        let room = maxParticles - survivorsCount - pending.count
        guard room > 0 else {
            return ParticleSpawnResult(requested: rule.burstCount, spawned: 0)
        }
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
                                 appearanceIndex: appearanceIndex,
                                 textureFrameSeed: textureFrameSeedSnapshot())
            refreshAppearance(&child)
            pending.append(child)
        }
        return ParticleSpawnResult(requested: rule.burstCount, spawned: count)
    }

    private mutating func appendEventParticles(_ eventParticles: [Particle]) -> ParticleSpawnResult {
        guard !eventParticles.isEmpty else {
            return ParticleSpawnResult(requested: 0, spawned: 0)
        }
        let room = maxParticles - particles.count
        guard room > 0 else {
            return ParticleSpawnResult(requested: eventParticles.count, spawned: 0)
        }
        let toAppend = min(eventParticles.count, room)
        particles.append(contentsOf: eventParticles.prefix(toAppend))
        lastFrameSpawnedParticles.append(contentsOf: eventParticles.prefix(toAppend))
        return ParticleSpawnResult(requested: eventParticles.count, spawned: toAppend)
    }

    private mutating func spawnDistanceEmission(from previous: SIMD3<Float>?,
                                                to current: SIMD3<Float>,
                                                worldTransform: simd_float4x4?,
                                                inheritedWorldVelocity: SIMD3<Float>,
                                                rateMultiplier: Float,
                                                maxLiveParticles: Int? = nil) -> ParticleSpawnResult {
        defer { previousEmitterPosition = current }
        guard distanceEmissionRate > 0,
              rateMultiplier > 0,
              let previous else {
            return ParticleSpawnResult(requested: 0, spawned: 0)
        }
        let delta = current - previous
        let distance = simd_length(delta)
        guard distance > 0.0001 else {
            return ParticleSpawnResult(requested: 0, spawned: 0)
        }

        distanceEmissionAccumulator += distance * distanceEmissionRate * rateMultiplier
        let toSpawn = Int(distanceEmissionAccumulator)
        guard toSpawn > 0 else {
            return ParticleSpawnResult(requested: 0, spawned: 0)
        }
        distanceEmissionAccumulator -= Float(toSpawn)

        switch simulationSpace {
        case .local:
            return spawn(toSpawn,
                         worldTransform: worldTransform,
                         inheritedWorldVelocity: inheritedWorldVelocity,
                         maxLiveParticles: maxLiveParticles)
        case .world:
            var spawned = 0
            for index in 0..<toSpawn {
                let t = (Float(index) + 0.5) / Float(toSpawn)
                let worldOrigin = previous + delta * t
                let spawnResult = spawn(1,
                                        worldTransform: worldTransform,
                                        worldOriginOverride: worldOrigin,
                                        inheritedWorldVelocity: inheritedWorldVelocity,
                                        maxLiveParticles: maxLiveParticles)
                spawned += spawnResult.spawned
            }
            return ParticleSpawnResult(requested: toSpawn, spawned: spawned)
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

    fileprivate var hasEventSubEmitterRules: Bool {
        legacySubEmitterRule != nil || subEmitters.contains(where: \.isActive)
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

    private func vectorFieldAcceleration(position: SIMD3<Float>, age: Float) -> SIMD3<Float> {
        guard vectorFieldMode != .none, vectorFieldStrength != 0 else { return .zero }
        switch vectorFieldMode {
        case .none:
            return .zero
        case .uniform:
            return normalizedOrDefault(vectorFieldDirection, SIMD3<Float>(0, 1, 0)) * vectorFieldStrength
        case .curl:
            let p = position * vectorFieldScale
            let phase = age * vectorFieldScrollSpeed + Float((seed >> 16) & 0xFFFF) * 0.0001
            let bias = normalizedOrDefault(vectorFieldDirection, SIMD3<Float>(0, 1, 0))
            let field = SIMD3<Float>(
                sineWave(p.y * 8.173 + p.z * 3.117 + phase)
                    - sineWave(p.z * 5.731 + p.x * 7.191 - phase),
                sineWave(p.z * 6.313 + p.x * 4.997 + phase + 1.37)
                    - sineWave(p.x * 9.239 + p.y * 2.173 - phase),
                sineWave(p.x * 4.113 + p.y * 7.911 + phase + 2.71)
                    - sineWave(p.y * 5.337 + p.z * 6.771 - phase)
            )
            let blended = field + bias * 0.25
            return normalizedOrDefault(blended, bias) * vectorFieldStrength
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

    private func textureFrameSeedSnapshot() -> UInt16 {
        UInt16(truncatingIfNeeded: rngState ^ (rngState >> 32))
    }

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
    mutating func advanceParticles(deltaTime: Double,
                                   options: ParticleAdvanceOptions = .default) -> Int {
        let particleEntities = entities(with: ParticleEmitter.self)
        let worldTransforms = Dictionary(uniqueKeysWithValues: particleEntities.map {
            ($0, worldTransform(for: $0)?.matrix ?? matrix_identity_float4x4)
        })
        let policy = resource(ParticleScalabilityPolicyResource.self) ?? .disabled
        let scalabilityState = policy.updatedState(
            previousStats: particleFrameStats,
            previousState: resource(ParticleScalabilityStateResource.self) ?? .default
        )
        setResource(scalabilityState)
        let effectiveOptions = scalabilityState.applying(to: options)
        var particleStats: [ParticleEmitterFrameStats] = []
        particleStats.reserveCapacity(particleEntities.count)
        let stepped = updateComponents(ParticleEmitter.self) { entity, emitter in
            emitter.advance(deltaTime: deltaTime,
                            worldTransform: worldTransforms[entity] ?? matrix_identity_float4x4,
                            options: effectiveOptions)
            particleStats.append(emitter.lastFrameStats)
        }
        setResource(ParticleFrameStatsResource(simulatedDeltaTime: Float(max(0, deltaTime)),
                                               emitterStats: particleStats))
        return stepped
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

    @discardableResult
    mutating func applyParticleSimulationEvents(
        _ eventsByEntity: [EntityID: [ParticleEvent]]
    ) -> ParticleSimulationEventApplyReport {
        var report = ParticleSimulationEventApplyReport(
            requestedEmitterCount: eventsByEntity.count,
            eventCount: eventsByEntity.values.reduce(0) { $0 + $1.count }
        )
        var emitterStats: [ParticleEmitterFrameStats] = []
        emitterStats.reserveCapacity(eventsByEntity.count)
        for (entity, events) in eventsByEntity {
            guard !events.isEmpty else {
                report.emptyEventEmitterCount += 1
                continue
            }
            var appliedStats: ParticleEmitterFrameStats?
            let updated = updateComponent(ParticleEmitter.self, for: entity) { emitter in
                let stats = emitter.applySimulationEvents(events)
                appliedStats = stats
                emitterStats.append(stats)
            }
            if updated, let appliedStats {
                report.appliedEmitterCount += 1
                report.appliedEventCount += events.count
                report.collisionEventCount += appliedStats.collisionCount
                report.deathEventCount += appliedStats.expiredParticleCount
                report.subEmitterSpawnedCount += appliedStats.subEmitterSpawnedCount
                report.spawnedParticleCount += appliedStats.spawnedParticleCount
                report.capacityLimitedSpawnCount += appliedStats.capacityLimitedSpawnCount
            } else {
                report.missingEmitterCount += 1
            }
        }
        if !emitterStats.isEmpty {
            setResource(
                ParticleFrameStatsResource(simulatedDeltaTime: 0,
                                           emitterStats: emitterStats)
            )
        }
        return report
    }
}

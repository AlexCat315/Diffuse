import EngineKernel
import SIMDCompat

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
    /// Multiplier applied to active simulation time. Zero pauses this emitter; one is real time.
    public var simulationSpeed: Float
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
    /// Maximum particles this emitter may spawn during one simulation frame. Zero is unlimited.
    public var maxSpawnedParticlesPerFrame: Int
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
    /// Emitter-level transparent sort priority. Lower values submit earlier; higher values draw later.
    public var renderSortPriority: Int
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

    // Simulation state is reset as a unit, independently of authored settings.
    var runtime = ParticleEmitterRuntimeState()

    public var particles: [Particle] { runtime.particles }
    public var lastFrameSpawnedParticles: [Particle] { runtime.lastFrameSpawnedParticles }
    public var lastFrameEvents: [ParticleEvent] { runtime.lastFrameEvents }
    public var lastFrameStats: ParticleEmitterFrameStats { runtime.lastFrameStats }

    public init(
        isEmitting: Bool = true,
        looping: Bool = true,
        duration: Float = 0,
        simulationSpeed: Float = 1,
        prewarmTime: Float = 0,
        prewarmStep: Float = 1.0 / 30.0,
        emissionRate: Float = 10,
        emissionRateCurve: ParticleCurve = .constant(1),
        distanceEmissionRate: Float = 0,
        distanceEmissionRateCurve: ParticleCurve = .constant(1),
        burstCount: Int = 0,
        burstInterval: Float = 0,
        maxParticles: Int = 256,
        maxSpawnedParticlesPerFrame: Int = 0,
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
        renderSortPriority: Int = 0,
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
        self.simulationSpeed = max(0, simulationSpeed)
        self.prewarmTime = max(0, prewarmTime)
        self.prewarmStep = max(1.0 / 240.0, prewarmStep)
        self.emissionRate = max(0, emissionRate)
        self.emissionRateCurve = emissionRateCurve
        self.distanceEmissionRate = max(0, distanceEmissionRate)
        self.distanceEmissionRateCurve = distanceEmissionRateCurve
        self.burstCount = max(0, burstCount)
        self.burstInterval = max(0, burstInterval)
        self.maxParticles = max(0, maxParticles)
        self.maxSpawnedParticlesPerFrame = max(0, maxSpawnedParticlesPerFrame)
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
        self.renderSortPriority = renderSortPriority
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
        self.runtime = ParticleEmitterRuntimeState(rngState: seed)
    }
}

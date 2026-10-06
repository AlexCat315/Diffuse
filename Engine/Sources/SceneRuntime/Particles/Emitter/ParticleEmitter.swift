import EngineKernel

/// Particle authoring settings and an independent, seeded simulation pool.
public struct ParticleEmitter: RuntimeComponent, Sendable, Equatable {
    public var settings: ParticleEmitterSettings
    /// Editor ordering and enabled states; simulation reads the typed settings.
    public var authoredModuleStack: ParticleModuleStack?
    var runtime: ParticleEmitterRuntimeState

    public var particles: [Particle] { runtime.particles }
    public var lastFrameSpawnedParticles: [Particle] { runtime.lastFrameSpawnedParticles }
    public var lastFrameEvents: [ParticleEvent] { runtime.lastFrameEvents }
    public var lastFrameStats: ParticleEmitterFrameStats { runtime.lastFrameStats }

    public init(settings: ParticleEmitterSettings = .init()) {
        self.settings = settings
        self.settings.normalize()
        self.runtime = ParticleEmitterRuntimeState(rngState: settings.emission.seed)
    }
}

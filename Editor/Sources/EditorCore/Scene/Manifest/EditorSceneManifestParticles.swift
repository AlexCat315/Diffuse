import SceneRuntime

/// The scene record stores the same grouped settings used by the runtime.
public struct EditorSceneManifestParticleEmitter: Codable, Sendable, Equatable {
    public let settings: ParticleEmitterSettings
    public let moduleStack: ParticleModuleStack?

    public init(_ component: ParticleEmitter) {
        settings = component.settings
        moduleStack = component.moduleStack
    }

    var component: ParticleEmitter {
        var emitter = ParticleEmitter(settings: settings)
        if let moduleStack { emitter.apply(moduleStack) }
        return emitter
    }
}

public extension ParticleEmitter {
    /// Creates a fresh simulation from the existing, domain-grouped authoring
    /// modules. Disabled modules retain the emitter's defaults.
    init(moduleStack: ParticleModuleStack) {
        self.init()
        apply(moduleStack)
    }
}

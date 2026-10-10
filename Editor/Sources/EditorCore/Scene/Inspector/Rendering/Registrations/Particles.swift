extension EditorInspectorRendererRegistry {
    /// Particle modules are authored as a fixed stack of groups, so the section
    /// needs the module layout rather than a flat field list.
    mutating func registerParticleRenderers() throws {
        try register(componentTypeID: "particleEmitter", layout: .particleModules) {
            $0.particleEmitterSection(for: $1)
        }
    }
}

public extension EditorInspectorRendererRegistry {
    /// Creates an independent set of optional rich controls for each editor.
    static var builtIn: Self {
        var registry = Self()
        // The built-in set is fixed: an invalid entry is a programming error here,
        // not a runtime condition the caller can recover from.
        try! registry.registerBuiltInRenderers()
        return registry
    }

    /// Installs every built-in rich control, grouped by the domain that owns the form.
    mutating func registerBuiltInRenderers() throws {
        try registerPhysicsRenderers()
        try registerParticleRenderers()
        try registerScriptRenderers()
        try registerAnimationRenderers()
    }
}

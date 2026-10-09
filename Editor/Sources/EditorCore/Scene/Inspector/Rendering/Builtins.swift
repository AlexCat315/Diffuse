public extension EditorInspectorRendererRegistry {
    /// Creates an independent set of optional rich controls for each editor.
    static var builtIn: Self {
        var registry = Self()
        let renderers: [(String, Renderer)] = [
            ("rigidbody", { $0.rigidBodySection(for: $1) }),
            ("collider", { $0.colliderSection(for: $1) }),
            ("destructible", { $0.destructibleSection(for: $1) }),
            ("vehicle", { $0.vehicleSection(for: $1) }),
            ("softBody", { $0.softBodySection(for: $1) }),
            ("cloth", { $0.clothSection(for: $1) }),
            ("softBodyMesh", { $0.softBodyMeshSection(for: $1) }),
            ("ragdoll", { $0.ragdollSection(for: $1) }),
            ("constraint", { $0.constraintSection(for: $1) }),
            ("script", { $0.scriptSection(for: $1) }),
            ("animationPlayer", { $0.animationPlayerSection(for: $1) }),
            ("animationGraphPlayer", { $0.animationGraphPlayerSection(for: $1) }),
            ("particleEmitter", { $0.particleEmitterSection(for: $1) }),
            ("renderMesh", { $0.renderMeshSection(for: $1) }),
            ("renderMaterial", { $0.renderMaterialSection(for: $1) }),
        ]
        for (typeID, render) in renderers {
            // Duplicate/empty IDs in this fixed list are programming errors.
            try! registry.register(componentTypeID: typeID, render: render)
        }
        return registry
    }
}

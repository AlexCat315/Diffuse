extension EditorInspectorRendererRegistry {
    /// Physics components own bespoke forms: compound colliders edit shape
    /// instances, joints and deformables expose authored sub-objects.
    mutating func registerPhysicsRenderers() throws {
        try register(componentTypeID: "collider", presentation: colliderSectionPresentation) {
            $0.colliderSection(for: $1)
        }
        try register(componentTypeID: "destructible") { $0.destructibleSection(for: $1) }
        try register(componentTypeID: "vehicle") { $0.vehicleSection(for: $1) }
        try register(componentTypeID: "softBody") { $0.softBodySection(for: $1) }
        try register(componentTypeID: "cloth") { $0.clothSection(for: $1) }
        try register(componentTypeID: "softBodyMesh") { $0.softBodyMeshSection(for: $1) }
        try register(componentTypeID: "ragdoll") { $0.ragdollSection(for: $1) }
        try register(componentTypeID: "constraint") { $0.constraintSection(for: $1) }
    }
}

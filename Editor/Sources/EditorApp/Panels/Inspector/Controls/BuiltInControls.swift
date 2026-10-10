import EditorCore

extension EditorInspectorFieldControlRegistry {
    /// Installs every compound control, grouped by the domain that owns the editor.
    mutating func registerBuiltInControls() throws {
        try registerPhysicsControls()
        try registerParticleControls()
        try registerEntityControls()
    }
}

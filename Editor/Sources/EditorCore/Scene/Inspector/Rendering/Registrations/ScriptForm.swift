extension EditorInspectorRendererRegistry {
    /// Script bindings are one collapsible sub-form per binding, each carrying
    /// its own header actions.
    mutating func registerScriptRenderers() throws {
        try register(componentTypeID: "script", layout: .scriptBindings) {
            $0.scriptSection(for: $1)
        }
    }
}

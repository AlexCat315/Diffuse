extension EditorInspectorRendererRegistry {
    mutating func registerAnimationRenderers() throws {
        try register(componentTypeID: "animationGraphPlayer") {
            $0.animationGraphPlayerSection(for: $1)
        }
    }
}

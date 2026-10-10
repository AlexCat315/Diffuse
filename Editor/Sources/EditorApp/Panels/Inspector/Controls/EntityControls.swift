import EditorCore
import GuavaUICompose

extension EditorInspectorFieldControlRegistry {
    /// Entity references resolve names from the options that travel with the field.
    mutating func registerEntityControls() throws {
        try register(controlID: .entityReference,
                     fallback: UInt64(0)) { binding, context in
            AnyView(InspectorPanel.InspectorEntityReferenceValue(binding: binding,
                                                                 options: context.entityOptions))
        }
    }
}

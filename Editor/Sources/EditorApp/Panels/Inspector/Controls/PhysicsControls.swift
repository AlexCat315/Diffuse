import EditorCore
import GuavaUICompose
import SceneRuntime

extension EditorInspectorFieldControlRegistry {
    /// Compound collider shapes own their per-entity selection state, so the
    /// control receives the panel's session state instead of caching it.
    mutating func registerPhysicsControls() throws {
        try register(controlID: .colliderShapeInstances,
                     fallback: [ColliderShapeInstance](),
                     layout: .fullWidth,
                     sizing: .intrinsic) { binding, context in
            AnyView(InspectorPanel.InspectorColliderShapeInstancesValue(binding: binding,
                                                                       session: context.colliderState))
        }
    }
}

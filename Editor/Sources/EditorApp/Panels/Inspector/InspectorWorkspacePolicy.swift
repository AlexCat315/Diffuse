import EditorCore

enum InspectorWorkspacePolicy {
    static func allows(_ kind: EditorComponentKind, in mode: EditorWorkspaceMode) -> Bool {
        let features = mode.profile.features
        switch kind {
        case .script: return features.contains(.scripting)
        case .characterController, .vehicle: return features.contains(.gameplay)
        case .rigidBody, .collider, .destructible, .softBody, .cloth, .softBodyMesh, .ragdoll:
            return features.contains(.simulation)
        case .animationPlayer, .animationGraphPlayer, .audioSource, .audioListener:
            return features.contains(.animation)
        default: return true
        }
    }
}

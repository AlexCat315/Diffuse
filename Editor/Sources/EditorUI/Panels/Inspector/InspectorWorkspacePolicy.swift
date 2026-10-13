import EditorCore
import SceneRuntime

enum InspectorWorkspacePolicy {
    static func allows(_ section: EditorInspectorSection, scene: EditorSceneAdapter, in mode: EditorWorkspaceMode) -> Bool {
        if let typeID = section.componentTypeID, let schema = scene.componentSchema(for: typeID) {
            return allows(schema, in: mode)
        }
        return mode.profile.allowsInspectorSection(section.id)
    }

    static func allows(_ schema: ComponentSchema, in mode: EditorWorkspaceMode) -> Bool {
        let features = mode.profile.features
        switch schema.category {
        case .scripting: return features.contains(.scripting)
        case .gameplay: return features.contains(.gameplay)
        case .physics: return features.contains(.simulation)
        case .animation, .audio: return features.contains(.animation)
        case .rendering, .assets: return true
        }
    }
}

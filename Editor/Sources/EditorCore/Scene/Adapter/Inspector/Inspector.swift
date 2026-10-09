import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    public func sceneSettingsSections() -> [EditorInspectorSection] {
        [physicsSettingsSection(), particleScalabilitySection()]
    }

    public func inspectorSections(for rawID: UInt64?) -> [EditorInspectorSection] {
        guard let entity = entity(from: rawID), scene.contains(entity) else {
            return []
        }

        var sections: [EditorInspectorSection] = [
            generalSection(for: entity),
            hierarchySection(for: entity),
            physicsSettingsSection(),
            particleScalabilitySection(),
        ]

        if let transformSection = transformSection(for: entity) {
            sections.append(transformSection)
        }
        for schema in scene.componentRegistry.componentSchemas where scene.hasComponent(typeID: schema.typeID, for: entity) {
            if var section = inspectorRenderers[schema.typeID]?(self, entity)
                ?? registryInspectorSection(schema, for: entity) {
                section.componentTypeID = schema.typeID
                sections.append(section)
            }
        }

        return sections
    }
}

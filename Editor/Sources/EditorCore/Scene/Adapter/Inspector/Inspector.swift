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
            if var section = customInspectorSection(schema.inspection.customEditor, for: entity)
                ?? registryInspectorSection(schema, for: entity) {
                section.componentTypeID = schema.typeID
                sections.append(section)
            }
        }

        return sections
    }
    /// Rich controls are optional renderers; unknown registrations always obtain
    /// the generic registry form without adding a component branch here.
    private func customInspectorSection(_ editor: String?, for entity: EntityID) -> EditorInspectorSection? {
        switch editor {
        case "rigidbody": rigidBodySection(for: entity)
        case "collider": colliderSection(for: entity)
        case "destructible": destructibleSection(for: entity)
        case "vehicle": vehicleSection(for: entity)
        case "softBody": softBodySection(for: entity)
        case "cloth": clothSection(for: entity)
        case "softBodyMesh": softBodyMeshSection(for: entity)
        case "ragdoll": ragdollSection(for: entity)
        case "constraint": constraintSection(for: entity)
        case "script": scriptSection(for: entity)
        case "animationPlayer": animationPlayerSection(for: entity)
        case "animationGraphPlayer": animationGraphPlayerSection(for: entity)
        case "particleEmitter": particleEmitterSection(for: entity)
        case "renderMesh": renderMeshSection(for: entity)
        case "renderMaterial": renderMaterialSection(for: entity)
        default: nil
        }
    }

}

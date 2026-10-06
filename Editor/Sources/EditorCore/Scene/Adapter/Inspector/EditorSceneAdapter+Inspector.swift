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
        if let rigidBodySection = rigidBodySection(for: entity) {
            sections.append(rigidBodySection)
        }
        if let colliderSection = colliderSection(for: entity) {
            sections.append(colliderSection)
        }
        if let destructibleSection = destructibleSection(for: entity) {
            sections.append(destructibleSection)
        }
        if let characterControllerSection = characterControllerSection(for: entity) {
            sections.append(characterControllerSection)
        }
        if let vehicleSection = vehicleSection(for: entity) {
            sections.append(vehicleSection)
        }
        if let softBodySection = softBodySection(for: entity) {
            sections.append(softBodySection)
        }
        if let clothSection = clothSection(for: entity) {
            sections.append(clothSection)
        }
        if let softBodyMeshSection = softBodyMeshSection(for: entity) {
            sections.append(softBodyMeshSection)
        }
        if let ragdollSection = ragdollSection(for: entity) {
            sections.append(ragdollSection)
        }
        if let constraintSection = constraintSection(for: entity) {
            sections.append(constraintSection)
        }
        if let lightSection = lightSection(for: entity) {
            sections.append(lightSection)
        }
        if let cameraSection = cameraSection(for: entity) {
            sections.append(cameraSection)
        }
        if let scriptSection = scriptSection(for: entity) {
            sections.append(scriptSection)
        }
        if let animationPlayerSection = animationPlayerSection(for: entity) {
            sections.append(animationPlayerSection)
        }
        if let animationGraphPlayerSection = animationGraphPlayerSection(for: entity) {
            sections.append(animationGraphPlayerSection)
        }
        if let audioSourceSection = audioSourceSection(for: entity) {
            sections.append(audioSourceSection)
        }
        if let audioListenerSection = audioListenerSection(for: entity) {
            sections.append(audioListenerSection)
        }
        if let particleEmitterSection = particleEmitterSection(for: entity) {
            sections.append(particleEmitterSection)
        }
        if let renderMeshSection = renderMeshSection(for: entity) {
            sections.append(renderMeshSection)
        }
        if let renderMaterialSection = renderMaterialSection(for: entity) {
            sections.append(renderMaterialSection)
        }

        return sections
    }
}

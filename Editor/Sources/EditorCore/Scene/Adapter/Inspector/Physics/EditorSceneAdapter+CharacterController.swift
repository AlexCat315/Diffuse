import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func characterControllerSection(for entity: EntityID) -> EditorInspectorSection? {
        guard scene.hasComponent(CharacterController.self, for: entity) else { return nil }
        return EditorInspectorSection(
            id: "character-controller",
            title: L("Character Controller"),
            fields: [
                EditorInspectorField(id: "character-radius", label: L("Radius"), value: .constrainedNumber(characterFloatBinding(for: entity, \.radius, min: 0.01), min: 0.01, max: nil, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "character-standing-height", label: L("Standing Half Height"), value: .constrainedNumber(characterFloatBinding(for: entity, \.standingHalfHeight, min: 0.01), min: 0.01, max: nil, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "character-crouching-height", label: L("Crouching Half Height"), value: .constrainedNumber(characterFloatBinding(for: entity, \.crouchingHalfHeight, min: 0.01), min: 0.01, max: nil, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "character-center", label: L("Center"), value: .vector3(
                    x: characterVectorBinding(for: entity, axis: \.x),
                    y: characterVectorBinding(for: entity, axis: \.y),
                    z: characterVectorBinding(for: entity, axis: \.z)
                )),
                EditorInspectorField(id: "character-slope", label: L("Max Slope"), value: .constrainedNumber(characterFloatBinding(for: entity, \.maxSlopeDegrees, min: 0, max: 89.9), min: 0, max: 89.9, step: 1, showsStepper: true)),
                EditorInspectorField(id: "character-step", label: L("Step Height"), value: .constrainedNumber(characterFloatBinding(for: entity, \.stepHeight, min: 0), min: 0, max: nil, step: 0.05, showsStepper: true)),
                EditorInspectorField(id: "character-skin", label: L("Skin Width"), value: .constrainedNumber(characterFloatBinding(for: entity, \.skinWidth, min: 0.001), min: 0.001, max: nil, step: 0.005, showsStepper: true)),
                EditorInspectorField(id: "character-mass", label: L("Mass"), value: .constrainedNumber(characterFloatBinding(for: entity, \.mass, min: 0.01), min: 0.01, max: nil, step: 1, showsStepper: true)),
                EditorInspectorField(id: "character-strength", label: L("Push Strength"), value: .constrainedNumber(characterFloatBinding(for: entity, \.maxStrength, min: 0), min: 0, max: nil, step: 10, showsStepper: true)),
                EditorInspectorField(id: "character-gravity", label: L("Gravity Scale"), value: .constrainedNumber(characterFloatBinding(for: entity, \.gravityScale), min: nil, max: nil, step: 0.1, showsStepper: true)),
            ]
        )
    }

    private func characterFloatBinding(
        for entity: EntityID,
        _ keyPath: WritableKeyPath<CharacterController, Float>,
        min minimum: Float? = nil,
        max maximum: Float? = nil
    ) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(CharacterController.self, for: entity)?[keyPath: keyPath] ?? 0 },
            set: { [self] next in
                var value = next
                if let minimum { value = Swift.max(minimum, value) }
                if let maximum { value = Swift.min(maximum, value) }
                guard scene.updateComponent(CharacterController.self, for: entity, {
                    $0[keyPath: keyPath] = value
                }) else { return }
                notifyRevisionChanged()
            }
        )
    }

    private func characterVectorBinding(
        for entity: EntityID,
        axis: WritableKeyPath<SIMD3<Float>, Float>
    ) -> Binding<Float> {
        Binding(
            get: { [self] in scene.component(CharacterController.self, for: entity)?.center[keyPath: axis] ?? 0 },
            set: { [self] next in
                guard scene.updateComponent(CharacterController.self, for: entity, {
                    $0.center[keyPath: axis] = next
                }) else { return }
                notifyRevisionChanged()
            }
        )
    }
}

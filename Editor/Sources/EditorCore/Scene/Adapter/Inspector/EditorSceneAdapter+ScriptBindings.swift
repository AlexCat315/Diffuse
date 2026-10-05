import Foundation
import AssetPipeline
import GuavaUIRuntime
import IntentRuntime
import RenderBackend
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func scriptSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let component = scene.component(ScriptComponent.self, for: entity) else {
            return nil
        }

        var fields: [EditorInspectorField] = []
        for (index, binding) in component.bindings.enumerated() {
            let ordinal = index + 1
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-identifier",
                    label: String(format: L("Script %d"), ordinal),
                    value: .stringOptions(scriptIdentifierBinding(for: entity, index: index),
                                          options: availableScriptOptions)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-enabled",
                    label: L("Enabled"),
                    value: .bool(scriptEnabledBinding(for: entity, index: index))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-status",
                    label: L("Status"),
                    value: .readOnly(scriptRuntime.canResolve(binding)
                                     ? L("Ready")
                                     : L("Missing script"))
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-parameters",
                    label: L("Parameters"),
                    value: .json(scriptParametersBinding(for: entity, index: index), minHeight: 96)
                )
            )
            fields.append(
                EditorInspectorField(
                    id: "script-\(index)-remove",
                    label: L("Binding"),
                    value: .action(title: L("Remove Script"), isDestructive: true) { [weak self] in
                        _ = self?.removeScriptBinding(from: entity.rawValue, at: index)
                    }
                )
            )
        }

        if fields.isEmpty {
            fields.append(
                EditorInspectorField(
                    id: "script-empty",
                    label: L("Bindings"),
                    value: .readOnly(L("No scripts"))
                )
            )
        }

        fields.append(
            EditorInspectorField(
                id: "script-add",
                label: L("Binding"),
                value: .action(title: L("Add Script"), isDestructive: false) { [weak self] in
                    _ = self?.addScriptBinding(to: entity.rawValue)
                }
            )
        )

        return EditorInspectorSection(id: "scripts", title: L("Scripts"), fields: fields)
    }

    private func scriptEnabledBinding(for entity: EntityID, index: Int) -> Binding<Bool> {
        Binding(
            get: { [self] in
                guard let bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index)
                else { return false }
                return bindings[index].isEnabled
            },
            set: { [self] next in
                guard var bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index),
                      bindings[index].isEnabled != next
                else { return }
                bindings[index].isEnabled = next
                _ = applySceneTransaction(intentVerb: "scene.set_script_enabled",
                                          summary: "Update script enabled flag",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setScriptBindings(entityID: entity.rawValue,
                                                                         bindings: bindings)])
            }
        )
    }

    private func scriptIdentifierBinding(for entity: EntityID, index: Int) -> Binding<String> {
        Binding(
            get: { [self] in
                guard let bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index) else { return "" }
                let binding = bindings[index]
                return binding.identifier
                    ?? scriptRuntime.identifier(for: binding.script)
                    ?? "handle:#\(binding.script.rawValue)"
            },
            set: { [self] next in
                let normalized = next.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !normalized.isEmpty,
                      var bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index),
                      bindings[index].identifier != normalized else { return }
                bindings[index].identifier = normalized
                bindings[index].script = scriptRuntime.handle(named: normalized)
                    ?? ScriptHandle(rawValue: 0)
                bindings[index].parametersJSON = "{}"
                _ = applySceneTransaction(intentVerb: "scene.set_script_identifier",
                                          summary: "Change script binding",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setScriptBindings(entityID: entity.rawValue,
                                                                         bindings: bindings)])
            }
        )
    }

    private func scriptParametersBinding(for entity: EntityID, index: Int) -> Binding<String> {
        Binding(
            get: { [self] in
                guard let bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index)
                else { return "{}" }
                return normalizedJSONCommitText(bindings[index].parametersJSON)
            },
            set: { [self] next in
                let normalized = normalizedJSONCommitText(next)
                guard isValidJSONDocument(normalized),
                      var bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
                      bindings.indices.contains(index),
                      bindings[index].parametersJSON != normalized
                else { return }
                bindings[index].parametersJSON = normalized
                _ = applySceneTransaction(intentVerb: "scene.set_script_parameters",
                                          summary: "Update script parameters",
                                          targetRawIDs: [entity.rawValue],
                                          mutations: [.setScriptBindings(entityID: entity.rawValue,
                                                                         bindings: bindings)])
            }
        )
    }
}

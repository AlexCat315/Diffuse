import Foundation
import GuavaUIRuntime
import SceneRuntime
import ScriptRuntime
import SIMDCompat

extension EditorSceneAdapter {
    func scriptSection(for entity: EntityID) -> EditorInspectorSection? {
        guard let component = scene.component(ScriptComponent.self, for: entity) else { return nil }
        var fields: [EditorInspectorField] = []
        var groups: [EditorInspectorFieldGroup] = []
        for (index, binding) in component.bindings.enumerated() {
            let prefix = "script-\(index)"
            let identifier = binding.identifier ?? scriptRuntime.identifier(for: binding.script) ?? ""
            let sourceIdentifier = dynamicScriptSourceIdentifier(for: identifier)
            let title = availableScriptOptions.first { $0.value == (sourceIdentifier ?? identifier) }?.label ?? identifier
            let definition = scriptRuntime.definition(for: binding)
            var propertyIDs: [String] = []
            fields += [
                EditorInspectorField(id: "\(prefix)-identifier", label: L("Script"),
                    value: .stringOptions(scriptIdentifierBinding(for: entity, id: binding.id), options: availableScriptOptions)),
                EditorInspectorField(id: "\(prefix)-enabled", label: L("Enabled"),
                    value: .bool(scriptEnabledBinding(for: entity, id: binding.id))),
                EditorInspectorField(id: "\(prefix)-status", label: L("Status"),
                    value: .readOnly(!scriptRuntime.canResolve(binding)
                        ? (sourceIdentifier == nil ? L("Missing script") : L("Not Built"))
                        : !binding.isEnabled ? L("Disabled")
                        : scriptRuntime.needsReload(binding, on: entity) ? L("Reload Pending")
                        : scriptRuntime.isActive(binding, on: entity) ? L("Running") : L("Loaded"))),
            ]
            for property in definition?.properties ?? [] {
                let fieldID = "\(prefix)-property-\(property.key)"
                propertyIDs.append(fieldID)
                fields.append(EditorInspectorField(id: fieldID, label: L(property.label),
                    value: scriptPropertyField(property, for: entity, id: binding.id), group: property.group.map { L($0) }))
            }
            if let definition {
                let issues = definition.parameterIssues(in: binding.parametersJSON)
                if !issues.isEmpty {
                    let fieldID = "\(prefix)-issues"
                    propertyIDs.append(fieldID)
                    fields.append(EditorInspectorField(id: fieldID, label: L("Parameter Issues"),
                        value: .readOnly(issues.map { issue in
                            switch issue {
                            case .invalidDocument: return L("Parameters must be a JSON object")
                            case .unknown(let key): return "\(L("Unknown parameter")): \(key)"
                            case .invalid(let key): return "\(L("Invalid parameter")): \(key)"
                            }
                        }.joined(separator: "; "))))
                }
            }
            if definition?.properties.isEmpty != false {
                let fieldID = "\(prefix)-interface"
                propertyIDs.append(fieldID)
                fields.append(EditorInspectorField(id: fieldID, label: L("Properties"),
                    value: .readOnly(definition == nil && sourceIdentifier != nil
                        ? L("Build script to load properties") : L("No exposed properties"))))
            }
            propertyIDs.append("\(prefix)-parameters")
            fields += [
                EditorInspectorField(id: "\(prefix)-parameters", label: L("Advanced Parameters (JSON)"),
                    value: .json(scriptParametersBinding(for: entity, id: binding.id), minHeight: 96), presentation: .advanced),
                EditorInspectorField(id: "\(prefix)-reset", label: L("Reset Properties"),
                    value: .action(title: L("Reset Properties"), isDestructive: false) { [weak self] in
                        self?.updateScriptBinding(for: entity, id: binding.id, verb: "scene.reset_script_parameters",
                                                  summary: "Reset script property overrides") { $0.parametersJSON = "{}" }
                    }),
                EditorInspectorField(id: "\(prefix)-remove", label: L("Remove Script"),
                    value: .action(title: L("Remove Script"), isDestructive: true) { [weak self] in
                        guard let self,
                              let bindings = self.scene.component(ScriptComponent.self, for: entity)?.bindings,
                              let currentIndex = bindings.firstIndex(where: { $0.id == binding.id }) else { return }
                        _ = self.removeScriptBinding(from: entity.rawValue, at: currentIndex)
                    }),
            ]
            groups.append(EditorInspectorFieldGroup(id: "scripts/\(binding.id.uuidString)",
                title: title.isEmpty ? L("Missing script") : title, fieldIDs: propertyIDs,
                enabledFieldID: "\(prefix)-enabled", statusFieldID: "\(prefix)-status",
                selectorFieldID: "\(prefix)-identifier", actionFieldIDs: ["\(prefix)-reset", "\(prefix)-remove"],
                sourceIdentifier: sourceIdentifier))
        }
        if fields.isEmpty {
            fields.append(EditorInspectorField(id: "script-empty", label: L("Scripts"), value: .readOnly(L("No scripts"))))
        }
        fields.append(EditorInspectorField(id: "script-add", label: "",
            value: .action(title: L("Add Script"), isDestructive: false) { [weak self] in
                _ = self?.addScriptBinding(to: entity.rawValue)
            }))
        return EditorInspectorSection(id: "scripts", title: L("Scripts"), fields: fields, groups: groups)
    }

    private func scriptBinding(for entity: EntityID, id: ScriptBindingID) -> ScriptBinding? {
        scene.component(ScriptComponent.self, for: entity)?.bindings.first { $0.id == id }
    }

    private func updateScriptBinding(for entity: EntityID, id: ScriptBindingID, verb: String,
                                     summary: String, update: (inout ScriptBinding) -> Void) {
        guard var bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
              let index = bindings.firstIndex(where: { $0.id == id }) else { return }
        let previous = bindings[index]
        update(&bindings[index])
        guard previous != bindings[index] else { return }
        _ = applySceneTransaction(intentVerb: verb, summary: summary, targetRawIDs: [entity.rawValue],
                                  mutations: [.setComponentData(entityID: entity.rawValue, typeID: "script", value: ComponentValue(jsonObject: ["bindings": (bindings).map(encodeScriptBindingForEditing)]))])
    }

    private func scriptEnabledBinding(for entity: EntityID, id: ScriptBindingID) -> Binding<Bool> {
        Binding(get: { [self] in scriptBinding(for: entity, id: id)?.isEnabled ?? false }, set: { [self] next in
            updateScriptBinding(for: entity, id: id, verb: "scene.set_script_enabled", summary: "Update script enabled flag") {
                $0.isEnabled = next
            }
        })
    }

    private func scriptIdentifierBinding(for entity: EntityID, id: ScriptBindingID) -> Binding<String> {
        Binding(get: { [self] in
            guard let binding = scriptBinding(for: entity, id: id) else { return "" }
            return binding.identifier ?? scriptRuntime.identifier(for: binding.script) ?? "handle:#\(binding.script.rawValue)"
        }, set: { [self] next in
            let normalized = next.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, scriptBinding(for: entity, id: id)?.identifier != normalized else { return }
            updateScriptBinding(for: entity, id: id, verb: "scene.set_script_identifier", summary: "Change script binding") {
                $0.identifier = normalized
                $0.script = scriptRuntime.handle(named: normalized) ?? ScriptHandle(rawValue: 0)
                $0.parametersJSON = "{}"
            }
        })
    }

    private func scriptParametersBinding(for entity: EntityID, id: ScriptBindingID) -> Binding<String> {
        Binding(get: { [self] in normalizedJSONCommitText(scriptBinding(for: entity, id: id)?.parametersJSON ?? "{}") },
                set: { [self] next in
            let normalized = normalizedJSONCommitText(next)
            guard let data = normalized.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else { return }
            updateScriptBinding(for: entity, id: id, verb: "scene.set_script_parameters", summary: "Update script parameters") {
                $0.parametersJSON = normalized
            }
        })
    }

    private func scriptPropertyValue(_ property: ScriptProperty, for entity: EntityID, id: ScriptBindingID) -> ScriptPropertyValue {
        guard let binding = scriptBinding(for: entity, id: id) else { return property.defaultValue }
        let overrides = ScriptDefinition.decodeParameters(binding.parametersJSON)
        let defaults = scriptRuntime.defaultParameters(for: binding)
        if let value = overrides[property.key], property.accepts(value), let decoded = property.defaultValue.decoding(value) { return decoded }
        if let value = defaults[property.key], property.accepts(value), let decoded = property.defaultValue.decoding(value) { return decoded }
        return property.defaultValue
    }

    private func setScriptProperty(_ property: ScriptProperty, value: ScriptPropertyValue, for entity: EntityID, id: ScriptBindingID) {
        guard property.accepts(value.jsonValue), let binding = scriptBinding(for: entity, id: id),
              scriptRuntime.definition(for: binding)?.properties.contains(property) == true else { return }
        var overrides = ScriptDefinition.decodeParameters(binding.parametersJSON)
        let defaults = scriptRuntime.defaultParameters(for: binding)
        let defaultValue = defaults[property.key].flatMap { property.defaultValue.decoding($0) } ?? property.defaultValue
        if value == defaultValue { overrides.removeValue(forKey: property.key) }
        else { overrides[property.key] = value.jsonValue }
        guard let json = ScriptDefinition.encodeParameters(overrides) else { return }
        updateScriptBinding(for: entity, id: id, verb: "scene.set_script_parameters", summary: "Update script property \(property.key)") {
            $0.parametersJSON = json
        }
    }

    private func scriptPropertyField(_ property: ScriptProperty, for entity: EntityID, id: ScriptBindingID) -> EditorInspectorFieldValue {
        func binding<Value>(_ read: @escaping (ScriptPropertyValue) -> Value,
                            _ write: @escaping (Value) -> ScriptPropertyValue) -> Binding<Value> {
            Binding(get: { [self] in read(scriptPropertyValue(property, for: entity, id: id)) },
                    set: { [self] in setScriptProperty(property, value: write($0), for: entity, id: id) })
        }
        switch property.defaultValue {
        case .string:
            let value = binding({ if case .string(let value) = $0 { return value }; return "" }, ScriptPropertyValue.string)
            return property.options.isEmpty ? .text(value) : .stringOptions(value, options: property.options.map {
                EditorInspectorStringOption(value: $0.value, label: L($0.label))
            })
        case .boolean:
            return .bool(binding({ if case .boolean(let value) = $0 { return value }; return false }, ScriptPropertyValue.boolean))
        case .number, .integer:
            let value = binding({ value -> Float in
                switch value { case .number(let n): return Float(n); case .integer(let n): return Float(n); default: return 0 }
            }, { value in
                if case .integer = property.defaultValue {
                    return .integer(Int(exactly: Double(value.rounded())) ?? 0)
                }
                return .number(Double(value))
            })
            return .constrainedNumber(value, min: property.minimum.map(Float.init), max: property.maximum.map(Float.init),
                                      step: property.step.map(Float.init) ?? (property.isInteger ? 1 : nil), showsStepper: false)
        case .entity:
            return .entityReference(binding({ if case .entity(let value) = $0 { return value }; return 0 }, ScriptPropertyValue.entity),
                options: [EditorInspectorEntityOption(id: 0, name: L("None"))] + scene.entities().map {
                    EditorInspectorEntityOption(id: $0.rawValue, name: scene.component(SceneNameComponent.self, for: $0)?.value ?? "Entity \($0.rawValue)")
                })
        case .vector3:
            func axis(_ index: Int) -> Binding<Float> {
                Binding(get: { [self] in
                    if case .vector3(let value) = scriptPropertyValue(property, for: entity, id: id) { return value[index] }; return 0
                }, set: { [self] next in
                    guard case .vector3(var value) = scriptPropertyValue(property, for: entity, id: id) else { return }
                    value[index] = next
                    setScriptProperty(property, value: .vector3(value), for: entity, id: id)
                })
            }
            return .vector3(x: axis(0), y: axis(1), z: axis(2))
        }
    }
}

private extension ScriptProperty {
    var isInteger: Bool { if case .integer = defaultValue { return true }; return false }
}

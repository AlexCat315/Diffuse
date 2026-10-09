import SceneRuntime
import ScriptRuntime

public struct EditorScriptCatalogApplyReport: Sendable, Equatable {
    public var registeredScriptCount: Int
    public var projectScriptCount: Int
    public var unresolvedBindings: [String]
}

extension EditorSceneAdapter {
    @discardableResult
    public func applyProjectScriptCatalog(
        _ catalog: ProjectScriptCatalog
    ) -> EditorScriptCatalogApplyReport {
        let nextIdentifiers = Set(catalog.entries.map(\.identifier))
        for identifier in managedScriptIdentifiers.subtracting(nextIdentifiers) {
            scriptRuntime.unregister(named: identifier)
        }
        for entry in catalog.entries {
            scriptRuntime.registerPreset(entry.preset,
                                         named: entry.identifier,
                                         defaultParametersJSON: entry.defaultParametersJSON)
        }
        managedScriptIdentifiers = nextIdentifiers
        scriptCatalogEntries = catalog.entries.sorted {
            if $0.isBuiltIn != $1.isBuiltIn { return $0.isBuiltIn }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }

        return EditorScriptCatalogApplyReport(
            registeredScriptCount: catalog.entries.count,
            projectScriptCount: catalog.entries.filter { !$0.isBuiltIn }.count,
            unresolvedBindings: unresolvedScriptBindingDescriptions()
        )
    }

    public var availableScriptOptions: [EditorInspectorStringOption] {
        let catalogOptions = scriptCatalogEntries.map {
            let suffix = $0.isBuiltIn ? "" : " · Project"
            return EditorInspectorStringOption(value: $0.identifier,
                                               label: $0.displayName + suffix)
        }
        let catalogIdentifiers = Set(catalogOptions.map(\.value))
        let dynamicOptions = dynamicScriptDisplayNames
            .filter { !catalogIdentifiers.contains($0.key) }
            .map {
                EditorInspectorStringOption(value: $0.key,
                                            label: $0.value + " · Swift")
            }
            .sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        return catalogOptions + dynamicOptions
    }

    public func registerDynamicScriptOption(identifier: String, displayName: String, legacyIdentifiers: [String] = []) {
        dynamicScriptDisplayNames[identifier] = displayName
        for alias in legacyIdentifiers { dynamicScriptAliases[alias] = identifier }
    }

    public func unregisterDynamicScriptOption(identifier: String) {
        dynamicScriptDisplayNames.removeValue(forKey: identifier)
        dynamicScriptAliases = dynamicScriptAliases.filter { $0.value != identifier }
    }

    public func setDynamicScriptOptions(_ options: [String: String], aliases: [String: String] = [:]) {
        dynamicScriptDisplayNames = options
        dynamicScriptAliases = aliases.filter { options[$0.value] != nil }
    }

    func dynamicScriptSourceIdentifier(for identifier: String) -> String? {
        let canonical = dynamicScriptAliases[identifier] ?? identifier
        return dynamicScriptDisplayNames[canonical] == nil ? nil : canonical
    }

    public func isScriptIdentifierAvailable(_ identifier: String) -> Bool {
        scriptRuntime.handle(named: identifier) != nil
    }

    @discardableResult
    public func addScriptBinding(to rawID: UInt64, identifier: String? = nil) -> Bool {
        guard isAuthoringEnabled,
              !isEntityLocked(rawID),
              let entity = scriptEntity(rawID) else { return false }
        var bindings = scene.component(ScriptComponent.self, for: entity)?.bindings ?? []
        bindings.append(ScriptBinding(identifier: identifier ?? defaultScriptIdentifier))
        return applySceneTransaction(intentVerb: "scene.add_script_binding",
                                     summary: "Add script binding",
                                     targetRawIDs: [rawID],
                                     mutations: [.setComponentData(entityID: rawID, typeID: "script", value: ComponentValue(jsonObject: ["bindings": (bindings).map(encodeScriptBindingForEditing)]))]) != nil
    }

    @discardableResult
    public func removeScriptBinding(from rawID: UInt64, at index: Int) -> Bool {
        guard isAuthoringEnabled,
              !isEntityLocked(rawID),
              let entity = scriptEntity(rawID),
              var bindings = scene.component(ScriptComponent.self, for: entity)?.bindings,
              bindings.indices.contains(index) else { return false }
        bindings.remove(at: index)
        return applySceneTransaction(intentVerb: "scene.remove_script_binding",
                                     summary: "Remove script binding",
                                     targetRawIDs: [rawID],
                                     mutations: [.setComponentData(entityID: rawID, typeID: "script", value: ComponentValue(jsonObject: ["bindings": (bindings).map(encodeScriptBindingForEditing)]))]) != nil
    }

    var defaultScriptIdentifier: String {
        if scriptRuntime.handle(named: "guava.rotator") != nil {
            return "guava.rotator"
        }
        return scriptCatalogEntries.first?.identifier ?? "guava.rotator"
    }

    public func unresolvedScriptBindingDescriptions(onlyEnabled: Bool = false) -> [String] {
        var descriptions: [String] = []
        for entity in scene.entities(with: ScriptComponent.self) {
            guard let bindings = scene.component(ScriptComponent.self, for: entity)?.bindings else {
                continue
            }
            let entityName = scene.component(SceneNameComponent.self, for: entity)?.value
                ?? "Entity \(entity.index)"
            for (index, binding) in bindings.enumerated()
                where (!onlyEnabled || binding.isEnabled) && !scriptRuntime.canResolve(binding) {
                let reference = binding.identifier ?? "handle #\(binding.script.rawValue)"
                descriptions.append("\(entityName) · binding \(index + 1): \(reference)")
            }
        }
        return descriptions
    }

    private func scriptEntity(_ rawID: UInt64) -> EntityID? {
        let entity = EntityID(rawValue: rawID)
        return scene.contains(entity) ? entity : nil
    }
}

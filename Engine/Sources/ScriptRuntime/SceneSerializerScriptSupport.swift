import Foundation
import SceneRuntime

extension SceneSerializer {

    /// Serializes a full scene including ScriptComponent bindings.
    /// Numeric script handles are NOT persisted because they are process-local. Stable
    /// identifiers, parameters and enabled flags are preserved.
    public static func serializeFull(_ scene: SceneRuntime) throws -> Data {
        guard let base = try JSONSerialization.jsonObject(with: serialize(scene)) as? [String: Any],
              var entities = base["entities"] as? [[String: Any]]
        else { return try serialize(scene) }

        // SceneSerializer's authored format deliberately omits derived destruction
        // entities. Mirror that list exactly or a skipped fragment shifts every later
        // script component onto the wrong serialized entity.
        let authoredEntities = scene.entities().filter { entity in
            scene.component(DestructibleFragment.self, for: entity) == nil
                && scene.component(DestructibleRetainedFragment.self, for: entity) == nil
        }
        for (i, entity) in authoredEntities.enumerated() {
            guard i < entities.count else { break }
            guard let sc = scene.component(ScriptComponent.self, for: entity) else { continue }
            var comps = entities[i]["components"] as? [String: Any] ?? [:]
            comps["script"] = ["bindings": sc.bindings.map { binding -> [String: Any] in
                var encoded: [String: Any] = [
                    "bindingID": binding.id.uuidString,
                    "parametersJSON": binding.parametersJSON,
                    "isEnabled": binding.isEnabled,
                ]
                if let identifier = binding.identifier {
                    encoded["identifier"] = identifier
                }
                return encoded
            }]
            entities[i]["components"] = comps
        }

        var merged = base
        merged["entities"] = entities
        return try JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys])
    }

    /// Deserializes a scene and restores ScriptComponent bindings.
    /// Script handles are set to rawValue 0 and resolve through their stable identifiers.
    public static func deserializeFull(_ data: Data, into scene: inout SceneRuntime) throws {
        let loadedEntities = try deserialize(data, into: &scene)
        restoreScriptBindings(from: data, entities: loadedEntities) { component, entity in
            _ = scene.setComponent(component, for: entity)
        }
    }
}

func restoreScriptBindings(from data: Data,
                           entities loadedEntities: [EntityID],
                           attach: (ScriptComponent, EntityID) -> Void) {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let entities = json["entities"] as? [[String: Any]]
    else { return }

    for (i, obj) in entities.enumerated() {
        guard i < loadedEntities.count else { break }
        guard let comps = obj["components"] as? [String: Any],
              let script = comps["script"] as? [String: Any],
              let bindings = script["bindings"] as? [[String: Any]]
        else { continue }

        let scriptBindings: [ScriptBinding] = bindings.map { b in
            ScriptBinding(
                ScriptHandle(rawValue: 0),
                id: (b["bindingID"] as? String).flatMap(ScriptBindingID.init(uuidString:))
                    ?? ScriptBindingID(),
                identifier: b["identifier"] as? String,
                isEnabled: b["isEnabled"] as? Bool ?? true,
                parametersJSON: b["parametersJSON"] as? String ?? "{}"
            )
        }
        attach(ScriptComponent(bindings: scriptBindings), loadedEntities[i])
    }
}

public extension Prefab {
    /// Native-host counterpart to ScriptContext.instantiate, including script bindings.
    @discardableResult
    func instantiateFull(into scene: inout SceneRuntime,
                         parent: EntityID? = nil,
                         transform: LocalTransform? = nil) throws -> EntityID? {
        let entities = try instantiateEntities(into: &scene, parent: parent, transform: transform)
        restoreScriptBindings(from: data, entities: entities) { component, entity in
            _ = scene.setComponent(component, for: entity)
        }
        return entities.first
    }

    /// Captures the hierarchy and stable script references as a reusable gameplay prefab.
    static func captureFull(from scene: SceneRuntime, root: EntityID) throws -> Prefab? {
        guard let prefab = try capture(from: scene, root: root),
              var document = try JSONSerialization.jsonObject(with: prefab.data) as? [String: Any],
              var entities = document["entities"] as? [[String: Any]] else { return nil }
        var ordered: [EntityID] = []
        func visit(_ entity: EntityID) {
            guard scene.component(DestructibleFragment.self, for: entity) == nil,
                  scene.component(DestructibleRetainedFragment.self, for: entity) == nil else { return }
            ordered.append(entity)
            for child in scene.children(of: entity) { visit(child) }
        }
        visit(root)
        for (index, entity) in ordered.enumerated() {
            guard let scripts = scene.component(ScriptComponent.self, for: entity) else { continue }
            var components = entities[index]["components"] as? [String: Any] ?? [:]
            components["script"] = ["bindings": scripts.bindings.map { binding -> [String: Any] in
                var value: [String: Any] = ["bindingID": binding.id.uuidString,
                                          "parametersJSON": binding.parametersJSON,
                                          "isEnabled": binding.isEnabled]
                if let identifier = binding.identifier { value["identifier"] = identifier }
                return value
            }]
            entities[index]["components"] = components
        }
        document["entities"] = entities
        return Prefab(data: try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]))
    }
}

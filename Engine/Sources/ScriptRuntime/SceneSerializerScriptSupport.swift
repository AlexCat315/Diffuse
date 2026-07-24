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

        let allEntities = scene.entities()
        for (i, entity) in allEntities.enumerated() {
            guard i < entities.count else { break }
            guard let sc = scene.component(ScriptComponent.self, for: entity) else { continue }
            var comps = entities[i]["components"] as? [String: Any] ?? [:]
            comps["script"] = ["bindings": sc.bindings.map { binding -> [String: Any] in
                var encoded: [String: Any] = [
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
        try deserialize(data, into: &scene)

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entities = json["entities"] as? [[String: Any]]
        else { return }

        let allEntities = scene.entities()
        for (i, obj) in entities.enumerated() {
            guard i < allEntities.count else { break }
            guard let comps = obj["components"] as? [String: Any],
                  let script = comps["script"] as? [String: Any],
                  let bindings = script["bindings"] as? [[String: Any]]
            else { continue }

            let scriptBindings: [ScriptBinding] = bindings.map { b in
                ScriptBinding(
                    ScriptHandle(rawValue: 0),
                    identifier: b["identifier"] as? String,
                    isEnabled: b["isEnabled"] as? Bool ?? true,
                    parametersJSON: b["parametersJSON"] as? String ?? "{}"
                )
            }
            _ = scene.setComponent(ScriptComponent(bindings: scriptBindings), for: allEntities[i])
        }
    }
}

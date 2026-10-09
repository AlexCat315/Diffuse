import Foundation
import SceneRuntime

public struct ScriptAuthoringDefaults: Sendable {
    public var identifier: String
    public init(identifier: String) { self.identifier = identifier }
}

public extension ComponentRegistry {
    /// Adds script persistence to this registry without changing another scene.
    mutating func registerScriptCodec(defaultIdentifier: String = "guava.rotator") {
        guard self["script"] == nil else { return }
        register(ComponentSchema(ScriptComponent.self, typeID: "script", displayName: "Script", category: .scripting,
            encode: { world, entity, context in
                world.component(ScriptComponent.self, for: entity).map {
                    ComponentValue(jsonObject: ["bindings": $0.bindings.map { binding in
                        context.purpose == .transaction ? encodeScriptBindingForEditing(binding) : encodeScriptBinding(binding)
                    }])
                }
            }, decode: { value, entity, context, world in
                guard let dictionary = value.objectValue else { return }
                let raw = dictionary["bindings"] as? [[String: Any]] ?? []
                _ = world.setComponent(ScriptComponent(bindings: raw.map(decodeScriptBinding)), for: entity)
            }, makeDefault: { entity, world in
                _ = world.setComponent(ScriptComponent(ScriptBinding(identifier: world.resource(ScriptAuthoringDefaults.self)?.identifier ?? defaultIdentifier)), for: entity)
            }, configure: { schema in
                schema.applyEdit = { value, entity, context, world in
                    guard let raw = value.objectValue?["bindings"] as? [[String: Any]] else { return }
                    let previous = world.component(ScriptComponent.self, for: entity)?.bindings ?? []
                    let bindings = raw.map { encoded in
                        var binding = decodeScriptBinding(encoded)
                        if let old = previous.first(where: { $0.id == binding.id && $0.identifier == binding.identifier }) {
                            binding.script = old.script
                        } else if let handle = encoded["scriptHandle"] as? NSNumber {
                            binding.script = ScriptHandle(rawValue: handle.uint64Value)
                        }
                        return binding
                    }
                    _ = world.setComponent(ScriptComponent(bindings: bindings), for: entity)
                }
            }))
    }
}

public func sceneDocumentScripts(in components: [ManifestComponent]) -> [ScriptBinding]? {
    guard let raw = components.value(for: "script")?.objectValue?["bindings"] as? [[String: Any]] else { return nil }
    return raw.map(decodeScriptBinding)
}

public func encodeScriptBinding(_ binding: ScriptBinding) -> [String: Any] {
    var value: [String: Any] = [
        "bindingID": binding.id.uuidString,
        "parametersJSON": binding.parametersJSON,
        "isEnabled": binding.isEnabled,
    ]
    if let identifier = binding.identifier { value["identifier"] = identifier }
    return value
}

public func decodeScriptBinding(_ value: [String: Any]) -> ScriptBinding {
    ScriptBinding(
        ScriptHandle(rawValue: 0),
        id: (value["bindingID"] as? String).flatMap(ScriptBindingID.init(uuidString:)) ?? ScriptBindingID(),
        identifier: value["identifier"] as? String,
        isEnabled: value["isEnabled"] as? Bool ?? true,
        parametersJSON: value["parametersJSON"] as? String ?? "{}"
    )
}

/// Transaction-only handle state; persistent scene documents use encodeScriptBinding.
public func encodeScriptBindingForEditing(_ binding: ScriptBinding) -> [String: Any] {
    var value = encodeScriptBinding(binding)
    value["scriptHandle"] = binding.script.rawValue
    return value
}

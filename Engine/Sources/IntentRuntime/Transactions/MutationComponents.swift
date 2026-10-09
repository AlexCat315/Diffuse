import SceneRuntime

/// The identity used by component edits and interactive undo grouping.
public struct SceneComponentKey: Hashable, Sendable {
    public let entityID: UInt64
    public let typeID: String

    public init(entityID: UInt64, typeID: String) {
        self.entityID = entityID
        self.typeID = typeID
    }
}

public extension SceneMutation {
    static func componentFields(entityID: UInt64, typeID: String,
                                fields: [String: Any]) -> SceneMutation {
        let values = fields.compactMapValues { value -> Any? in
            let mirror = Mirror(reflecting: value)
            return mirror.displayStyle == .optional ? mirror.children.first?.value : value
        }
        return .setComponentData(entityID: entityID, typeID: typeID,
                                 value: ComponentValue(jsonObject: values), mode: .merge)
    }

    /// Uses the registered codec even when the caller already holds a typed value.
    /// Reference-bearing values should be encoded in their source scene instead.
    static func componentData<Component: RuntimeComponent>(
        entityID: UInt64, typeID: String, component: Component,
        registry: ComponentRegistry = .builtIn
    ) -> SceneMutation {
        var world = RuntimeWorld(componentRegistry: registry)
        let entity = world.createEntity()
        _ = world.setComponent(component, for: entity)
        var context = ComponentEncodeContext(entityIndexMap: [:])
        context.purpose = .gameSave
        guard let schema = registry[typeID],
              let value = schema.encode(world, entity, &context) else {
            preconditionFailure("Component codec unavailable: \(typeID)")
        }
        return .setComponentData(entityID: entityID, typeID: typeID, value: value)
    }
}

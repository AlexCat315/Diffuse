import IntentRuntime
import SceneRuntime
import ScriptRuntime

extension SceneMutation {
    func decodedComponent<Component: RuntimeComponent>(_ type: Component.Type,
                                                       typeID: String) -> (UInt64, Component)? {
        guard case let .setComponentData(id, actualType, value, _) = self,
              typeID == actualType else { return nil }
        var registry = ComponentRegistry.builtIn
        registry.registerScriptCodec()
        var scene = SceneRuntime(componentRegistry: registry)
        let entity = scene.createEntity()
        try? scene.setComponentData(value, typeID: typeID, for: entity)
        return scene.component(type, for: entity).map { (id, $0) }
    }
}

extension TransactionOperation {
    func decodedComponent<Component: RuntimeComponent>(_ type: Component.Type,
                                                       typeID: String) -> (UInt64, Component)? {
        guard case let .scene(mutation) = self else { return nil }
        return mutation.decodedComponent(type, typeID: typeID)
    }
}

import SceneRuntime

/// Last reported gameplay values, inspectable by editor tools without loading
/// user-defined Swift types or exposing a runtime object to the assistant.
public struct ScriptDebugState: Sendable {
    public var entities: [EntityID: [String: String]] = [:]
    public init() {}
}

public extension ScriptContext {
    func reportState(_ values: [String: String]) {
        var state = resource(ScriptDebugState.self) ?? ScriptDebugState()
        state.entities[entity] = values.keys.sorted().prefix(32).reduce(into: [:]) {
            $0[String($1.prefix(128))] = String((values[$1] ?? "").prefix(1024))
        }
        setResource(state)
    }
}

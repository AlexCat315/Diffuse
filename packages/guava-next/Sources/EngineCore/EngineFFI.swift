import CEngineBridge

public struct BridgedEngineRuntime: EngineRuntime {
    public init() {}

    public func initialize() {
        engine_bridge_initialize()
    }

    public func update(deltaTime: Double) {
        engine_bridge_update(deltaTime)
    }

    public func shutdown() {
        engine_bridge_shutdown()
    }
}

import CEngineBridge

public struct BridgedEngineRuntime: EngineRuntime {
    public init() {}

    public func initialize() {
        engine_bridge_initialize()
    }

    public func tickInput(deltaTime: Double) {
        engine_bridge_tick_input(deltaTime)
    }

    public func tickSimulation(deltaTime: Double) {
        engine_bridge_tick_simulation(deltaTime)
    }

    public func tickRenderPrepare(deltaTime: Double) {
        engine_bridge_tick_render_prepare(deltaTime)
    }

    public func tickRenderSubmit(deltaTime: Double) {
        engine_bridge_tick_render_submit(deltaTime)
    }

    public func shutdown() {
        engine_bridge_shutdown()
    }
}

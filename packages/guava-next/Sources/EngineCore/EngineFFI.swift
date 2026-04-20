import CEngineBridge

public struct BridgedEngineRuntime: EngineRuntime {
    public init() {}

    public func initialize() {
        engine_init()
    }

    public func tickInput(deltaTime: Double) {
        engine_tick_input(deltaTime)
    }

    public func tickSimulation(deltaTime: Double) {
        engine_tick_sim(deltaTime)
    }

    public func tickRenderPrepare(deltaTime: Double) {
        engine_tick_render_prepare(deltaTime)
    }

    public func tickRenderSubmit(deltaTime: Double) {
        engine_tick_render_submit(deltaTime)
    }

    public func shutdown() {
        engine_shutdown()
    }
}

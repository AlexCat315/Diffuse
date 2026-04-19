public protocol EngineRuntime {
    func initialize()
    func update(deltaTime: Double)
    func shutdown()
}

public final class EngineHost {
    private let runtime: any EngineRuntime

    public init(runtime: any EngineRuntime) {
        self.runtime = runtime
    }

    public func start() {
        runtime.initialize()
    }

    public func tick(deltaTime: Double) {
        runtime.update(deltaTime: deltaTime)
    }

    deinit {
        runtime.shutdown()
    }
}

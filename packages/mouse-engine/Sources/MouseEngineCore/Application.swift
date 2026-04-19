import MouseRHI

public struct EngineConfig: Sendable {
    public var projectPath: String
    public var targetFPS: Int

    public init(projectPath: String = ".", targetFPS: Int = 60) {
        self.projectPath = projectPath
        self.targetFPS = targetFPS
    }
}

public final class Application {
    public private(set) var isRunning: Bool = false
    public let config: EngineConfig
    private let world = World()

    public init(config: EngineConfig = .init()) {
        self.config = config
    }

    public func start() {
        isRunning = true
    }

    public func tick(deltaTime: Float) {
        guard isRunning else { return }
        world.update(deltaTime: deltaTime)
    }

    public func stop() {
        isRunning = false
    }
}

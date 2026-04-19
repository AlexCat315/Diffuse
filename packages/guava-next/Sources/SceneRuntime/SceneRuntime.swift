public struct SceneRuntimeSnapshot: Sendable {
    public var entityCount: Int
    public var revision: UInt64

    public init(entityCount: Int = 0, revision: UInt64 = 0) {
        self.entityCount = entityCount
        self.revision = revision
    }
}

public struct SceneRuntime {
    public private(set) var snapshot: SceneRuntimeSnapshot = .init()

    public init() {}

    public mutating func tick() {
        snapshot.revision += 1
    }
}

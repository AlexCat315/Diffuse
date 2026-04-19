public struct Entity: Sendable, Hashable {
    public let id: UInt64
    public init(id: UInt64) { self.id = id }
}

public final class World {
    private var nextID: UInt64 = 1
    private var entities: Set<Entity> = []

    public init() {}

    @discardableResult
    public func createEntity() -> Entity {
        let e = Entity(id: nextID)
        nextID += 1
        entities.insert(e)
        return e
    }

    public func destroyEntity(_ entity: Entity) {
        entities.remove(entity)
    }

    public func update(deltaTime: Float) {
        _ = deltaTime
    }

    public var count: Int { entities.count }
}

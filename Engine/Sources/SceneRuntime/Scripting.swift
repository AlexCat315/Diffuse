import simd

public protocol RuntimeScriptDriver: AnyObject, Sendable {
    func run(context: inout RuntimeScriptPhaseContext)
    func reset()
}

public struct RuntimeScriptPhaseContext {
    private let worldPointer: UnsafeMutablePointer<RuntimeWorld>
    private let commandBufferPointer: UnsafeMutablePointer<RuntimeCommandBuffer>
    private let deltaTimeSecondsValue: Double

    init(
        world: UnsafeMutablePointer<RuntimeWorld>,
        commands: UnsafeMutablePointer<RuntimeCommandBuffer>,
        deltaTimeSeconds: Double
    ) {
        self.worldPointer = world
        self.commandBufferPointer = commands
        self.deltaTimeSecondsValue = deltaTimeSeconds
    }

    public var deltaTimeSeconds: Double {
        deltaTimeSecondsValue
    }

    public func entities() -> [EntityID] {
        worldPointer.pointee.entities()
    }

    public func contains(_ entity: EntityID) -> Bool {
        worldPointer.pointee.contains(entity)
    }

    public func component<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID
    ) -> Component? {
        worldPointer.pointee.component(type, for: entity)
    }

    public func hasComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID
    ) -> Bool {
        worldPointer.pointee.hasComponent(type, for: entity)
    }

    @discardableResult
    public func setComponent<Component: RuntimeComponent>(
        _ component: Component,
        for entity: EntityID
    ) -> Bool {
        worldPointer.pointee.setComponent(component, for: entity)
    }

    @discardableResult
    public func updateComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID,
        _ body: (inout Component) -> Void
    ) -> Bool {
        worldPointer.pointee.updateComponent(type, for: entity, body)
    }

    @discardableResult
    public func removeComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        from entity: EntityID
    ) -> Component? {
        worldPointer.pointee.removeComponent(type, from: entity)
    }

    public func localTransform(for entity: EntityID) -> LocalTransform? {
        worldPointer.pointee.localTransform(for: entity)
    }

    public func worldTransform(for entity: EntityID) -> WorldTransform? {
        refreshTransformsIfNeeded()
        return worldPointer.pointee.worldTransform(for: entity)
    }

    @discardableResult
    public func setLocalTransform(_ transform: LocalTransform, for entity: EntityID) -> Bool {
        let updated = worldPointer.pointee.setLocalTransform(transform, for: entity)
        refreshTransformsIfNeeded()
        return updated
    }

    @discardableResult
    public func translate(_ delta: SIMD3<Float>, for entity: EntityID) -> Bool {
        guard var transform = worldPointer.pointee.localTransform(for: entity) else {
            return false
        }
        transform.matrix.columns.3.x += delta.x
        transform.matrix.columns.3.y += delta.y
        transform.matrix.columns.3.z += delta.z
        let updated = worldPointer.pointee.setLocalTransform(transform, for: entity)
        refreshTransformsIfNeeded()
        return updated
    }

    public func parent(of entity: EntityID) -> EntityID? {
        worldPointer.pointee.parent(of: entity)
    }

    public func children(of entity: EntityID) -> [EntityID] {
        worldPointer.pointee.children(of: entity)
    }

    @discardableResult
    public func setParent(_ parent: EntityID?, for child: EntityID) -> Bool {
        let updated = worldPointer.pointee.setParent(parent, for: child)
        refreshTransformsIfNeeded()
        return updated
    }

    public func enqueueDestroyEntity(_ entity: EntityID) {
        commandBufferPointer.pointee.destroyEntity(entity)
    }

    public func enqueueSetParent(_ parent: EntityID?, for child: EntityID) {
        commandBufferPointer.pointee.setParent(parent, for: child)
    }

    public func enqueueSetLocalTransform(_ transform: LocalTransform, for entity: EntityID) {
        commandBufferPointer.pointee.setLocalTransform(transform, for: entity)
    }

    public func physicsRaycast(
        _ query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsRaycastHit? {
        refreshTransformsIfNeeded()
        return performPhysicsRaycast(query, filter: filter, using: buildSpatialIndexResource(in: worldPointer.pointee))
    }

    public func physicsOverlapAABB(
        _ query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> [PhysicsOverlapHit] {
        refreshTransformsIfNeeded()
        return performPhysicsOverlapAABB(query, filter: filter, using: buildSpatialIndexResource(in: worldPointer.pointee))
    }

    public func physicsSweepAABB(
        _ query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsSweepHit? {
        refreshTransformsIfNeeded()
        return performPhysicsSweepAABB(query, filter: filter, using: buildSpatialIndexResource(in: worldPointer.pointee))
    }

    public func resource<Resource: Sendable>(_ type: Resource.Type) -> Resource? {
        worldPointer.pointee.resource(type)
    }

    public func setResource<Resource: Sendable>(_ resource: Resource) {
        worldPointer.pointee.setResource(resource)
    }

    @discardableResult
    public func updateResource<Resource: Sendable>(
        _ type: Resource.Type,
        _ body: (inout Resource) -> Void
    ) -> Bool {
        worldPointer.pointee.updateResource(type, body)
    }

    @discardableResult
    public func removeResource<Resource: Sendable>(_ type: Resource.Type) -> Resource? {
        worldPointer.pointee.removeResource(type)
    }

    public func propagateTransformsIfNeeded() {
        refreshTransformsIfNeeded()
    }

    private func refreshTransformsIfNeeded() {
        if worldPointer.pointee.hierarchyNeedsPropagation() {
            worldPointer.pointee.propagateTransforms()
        }
    }
}
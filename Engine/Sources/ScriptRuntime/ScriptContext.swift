import SceneRuntime
import simd

public final class ScriptContext {
    private let phaseContext: RuntimeScriptPhaseContext

    public let entity: EntityID
    public let deltaTime: Double

    init(phaseContext: RuntimeScriptPhaseContext, entity: EntityID, deltaTime: Double) {
        self.phaseContext = phaseContext
        self.entity = entity
        self.deltaTime = deltaTime
    }

    public var isAlive: Bool {
        phaseContext.contains(entity)
    }

    public func contains(_ entity: EntityID) -> Bool {
        phaseContext.contains(entity)
    }

    public func component<Component: RuntimeComponent>(_ type: Component.Type) -> Component? {
        phaseContext.component(type, for: entity)
    }

    public func component<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID
    ) -> Component? {
        phaseContext.component(type, for: entity)
    }

    public func hasComponent<Component: RuntimeComponent>(_ type: Component.Type) -> Bool {
        phaseContext.hasComponent(type, for: entity)
    }

    public func hasComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID
    ) -> Bool {
        phaseContext.hasComponent(type, for: entity)
    }

    @discardableResult
    public func setComponent<Component: RuntimeComponent>(_ component: Component) -> Bool {
        phaseContext.setComponent(component, for: entity)
    }

    @discardableResult
    public func setComponent<Component: RuntimeComponent>(
        _ component: Component,
        for entity: EntityID
    ) -> Bool {
        phaseContext.setComponent(component, for: entity)
    }

    @discardableResult
    public func updateComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        _ body: (inout Component) -> Void
    ) -> Bool {
        phaseContext.updateComponent(type, for: entity, body)
    }

    @discardableResult
    public func updateComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        for entity: EntityID,
        _ body: (inout Component) -> Void
    ) -> Bool {
        phaseContext.updateComponent(type, for: entity, body)
    }

    @discardableResult
    public func removeComponent<Component: RuntimeComponent>(_ type: Component.Type) -> Component? {
        phaseContext.removeComponent(type, from: entity)
    }

    @discardableResult
    public func removeComponent<Component: RuntimeComponent>(
        _ type: Component.Type,
        from entity: EntityID
    ) -> Component? {
        phaseContext.removeComponent(type, from: entity)
    }

    public var localTransform: LocalTransform? {
        phaseContext.localTransform(for: entity)
    }

    public func localTransform(of entity: EntityID) -> LocalTransform? {
        phaseContext.localTransform(for: entity)
    }

    public var worldTransform: WorldTransform? {
        phaseContext.worldTransform(for: entity)
    }

    public func worldTransform(of entity: EntityID) -> WorldTransform? {
        phaseContext.worldTransform(for: entity)
    }

    @discardableResult
    public func setLocalTransform(_ transform: LocalTransform) -> Bool {
        phaseContext.setLocalTransform(transform, for: entity)
    }

    @discardableResult
    public func setLocalTransform(_ transform: LocalTransform, for entity: EntityID) -> Bool {
        phaseContext.setLocalTransform(transform, for: entity)
    }

    @discardableResult
    public func translate(by delta: SIMD3<Float>) -> Bool {
        phaseContext.translate(delta, for: entity)
    }

    @discardableResult
    public func translate(_ delta: SIMD3<Float>, for entity: EntityID) -> Bool {
        phaseContext.translate(delta, for: entity)
    }

    public func parent() -> EntityID? {
        phaseContext.parent(of: entity)
    }

    public func parent(of entity: EntityID) -> EntityID? {
        phaseContext.parent(of: entity)
    }

    public func children() -> [EntityID] {
        phaseContext.children(of: entity)
    }

    public func children(of entity: EntityID) -> [EntityID] {
        phaseContext.children(of: entity)
    }

    @discardableResult
    public func setParent(_ parent: EntityID?) -> Bool {
        phaseContext.setParent(parent, for: entity)
    }

    @discardableResult
    public func setParent(_ parent: EntityID?, for child: EntityID) -> Bool {
        phaseContext.setParent(parent, for: child)
    }

    public func physicsRaycast(
        _ query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsRaycastHit? {
        phaseContext.physicsRaycast(query, filter: filter)
    }

    public func raycast(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maxDistance: Float,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsRaycastHit? {
        phaseContext.physicsRaycast(
            PhysicsRaycastQuery(
                origin: origin,
                direction: direction,
                maxDistance: maxDistance
            ),
            filter: filter
        )
    }

    public func physicsOverlapAABB(
        _ query: PhysicsOverlapAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> [PhysicsOverlapHit] {
        phaseContext.physicsOverlapAABB(query, filter: filter)
    }

    public func overlap(
        bounds: SpatialAABB,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> [PhysicsOverlapHit] {
        phaseContext.physicsOverlapAABB(PhysicsOverlapAABBQuery(bounds: bounds), filter: filter)
    }

    public func physicsSweepAABB(
        _ query: PhysicsSweepAABBQuery,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsSweepHit? {
        phaseContext.physicsSweepAABB(query, filter: filter)
    }

    public func sweep(
        bounds: SpatialAABB,
        translation: SIMD3<Float>,
        filter: PhysicsQueryFilter = PhysicsQueryFilter()
    ) -> PhysicsSweepHit? {
        phaseContext.physicsSweepAABB(
            PhysicsSweepAABBQuery(bounds: bounds, translation: translation),
            filter: filter
        )
    }

    public func resource<Resource: Sendable>(_ type: Resource.Type) -> Resource? {
        phaseContext.resource(type)
    }

    public func setResource<Resource: Sendable>(_ resource: Resource) {
        phaseContext.setResource(resource)
    }

    @discardableResult
    public func updateResource<Resource: Sendable>(
        _ type: Resource.Type,
        _ body: (inout Resource) -> Void
    ) -> Bool {
        phaseContext.updateResource(type, body)
    }

    @discardableResult
    public func removeResource<Resource: Sendable>(_ type: Resource.Type) -> Resource? {
        phaseContext.removeResource(type)
    }

    public func destroyEntity(_ entity: EntityID) {
        phaseContext.enqueueDestroyEntity(entity)
    }

    public func destroySelf() {
        phaseContext.enqueueDestroyEntity(entity)
    }
}
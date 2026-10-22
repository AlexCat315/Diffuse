import SIMDCompat

public struct PhysicsQueryCacheStats: Sendable, Equatable {
    public var sourceRevision: UInt64?
    public var bodyCount: Int
    public var constraintCount: Int
    public var queryCount: Int
    public var rebuildCount: Int
    public var cacheHitCount: Int

    public init(
        sourceRevision: UInt64? = nil,
        bodyCount: Int = 0,
        constraintCount: Int = 0,
        queryCount: Int = 0,
        rebuildCount: Int = 0,
        cacheHitCount: Int = 0
    ) {
        self.sourceRevision = sourceRevision
        self.bodyCount = bodyCount
        self.constraintCount = constraintCount
        self.queryCount = queryCount
        self.rebuildCount = rebuildCount
        self.cacheHitCount = cacheHitCount
    }
}

/// Mirrors the world's physics state into a backend so spatial queries can run
/// outside the simulation phase. Holds the protocol rather than a concrete engine
/// so any `PhysicsBackend` implementation can be queried this way.
final class PhysicsQueryScene: @unchecked Sendable {
    private var backend: any PhysicsBackend
    private var sourceRevision: UInt64?
    private var bodyCount = 0
    private var constraintCount = 0
    private var queryCount = 0
    private var rebuildCount = 0
    private var cacheHitCount = 0

    init(backend: any PhysicsBackend) {
        self.backend = backend
    }

    func backend(in world: RuntimeWorld) -> any PhysicsBackend {
        queryCount += 1
        if sourceRevision == world.physicsRevision {
            cacheHitCount += 1
        }
        return synchronize(in: world)
    }

    func synchronize(in world: RuntimeWorld) -> any PhysicsBackend {
        guard sourceRevision != world.physicsRevision else {
            return backend
        }

        let snapshot = buildPhysicsSceneSnapshot(in: world)
        _ = backend.prepare(
            context: PhysicsPrepareContext(
                settings: snapshot.settings,
                deltaTimeSeconds: 0,
                activeBodies: snapshot.bodies,
                activeConstraints: snapshot.constraints,
                syncEvents: [],
                activeCharacters: snapshot.characters,
                isFullSnapshot: true
            )
        )
        sourceRevision = world.physicsRevision
        bodyCount = snapshot.bodies.count
        constraintCount = snapshot.constraints.count
        rebuildCount += 1
        return backend
    }

    func adoptSynchronizedWorld(
        _ world: RuntimeWorld,
        bodyCount: Int,
        constraintCount: Int
    ) {
        sourceRevision = world.physicsRevision
        self.bodyCount = bodyCount
        self.constraintCount = constraintCount
    }

    func replaceBackend(_ next: any PhysicsBackend) {
        backend = next
        invalidate()
    }

    func invalidate() {
        sourceRevision = nil
        bodyCount = 0
        constraintCount = 0
    }

    var stats: PhysicsQueryCacheStats {
        PhysicsQueryCacheStats(
            sourceRevision: sourceRevision,
            bodyCount: bodyCount,
            constraintCount: constraintCount,
            queryCount: queryCount,
            rebuildCount: rebuildCount,
            cacheHitCount: cacheHitCount
        )
    }
}

func buildPhysicsSceneSnapshot(
    in world: RuntimeWorld,
    settings overrideSettings: PhysicsSettingsResource? = nil
) -> (
    settings: PhysicsSettingsResource,
    bodies: [PhysicsBodyDescriptor],
    constraints: [PhysicsConstraintDescriptor],
    characters: [PhysicsCharacterDescriptor]
) {
    // The backend selection lives in the settings the caller already carries; this
    // snapshot must not claim an engine of its own.
    let settings = overrideSettings ?? world.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()

    let entities = world.entities()
    let localTransforms = world.localTransformSnapshot(matching: entities)
    let worldTransforms = world.worldTransformSnapshot(matching: entities)
    let rigidBodies = world.componentSnapshot(RigidBody.self, matching: entities)
    let colliders = world.componentSnapshot(Collider.self, matching: entities)
    let constraints = world.componentSnapshot(Constraint.self, matching: entities)
    let characters = world.componentSnapshot(CharacterController.self, matching: entities)
    let geometryResource = world.resource(MeshColliderGeometryResource.self)
    let meshBounds = world.resource(MeshColliderBoundsResource.self)

    let bodies = entities.compactMap { entity -> PhysicsBodyDescriptor? in
        let rigidBody = rigidBodies[entity]
        var collider = colliders[entity]
        var meshGeometry: MeshColliderGeometry?
        if let currentCollider = collider {
            let geometry = geometryResource?.geometry(for: currentCollider.shape.resourceID)
            let resolvedShape = resolvedColliderShape(currentCollider.shape,
                                                      meshGeometry: geometry,
                                                      meshBounds: meshBounds)
            if resolvedShape == currentCollider.shape {
                meshGeometry = geometry
            } else {
                collider = Collider(
                    shape: resolvedShape,
                    isTrigger: currentCollider.isTrigger,
                    layerID: currentCollider.layerID,
                    layerMask: currentCollider.layerMask,
                    material: currentCollider.material
                )
            }
        }
        guard rigidBody != nil || collider != nil,
              let localTransform = localTransforms[entity],
              let worldTransform = worldTransforms[entity] else {
            return nil
        }
        return PhysicsBodyDescriptor(
            entity: entity,
            localTransform: localTransform,
            worldTransform: worldTransform,
            rigidBody: rigidBody,
            collider: collider,
            meshGeometry: meshGeometry
        )
    }

    let constraintDescriptors = entities.compactMap { entity -> PhysicsConstraintDescriptor? in
        guard let constraint = constraints[entity],
              let worldTransform = worldTransforms[entity] else {
            return nil
        }
        return PhysicsConstraintDescriptor(
            entity: entity,
            worldTransform: worldTransform,
            constraint: constraint
        )
    }

    let characterDescriptors = entities.compactMap { entity -> PhysicsCharacterDescriptor? in
        guard let controller = characters[entity],
              let worldTransform = worldTransforms[entity] else { return nil }
        return PhysicsCharacterDescriptor(
            entity: entity,
            worldTransform: worldTransform,
            controller: controller
        )
    }

    return (settings, bodies, constraintDescriptors, characterDescriptors)
}

import SIMDCompat

func makeJoltQueryBackend(in world: RuntimeWorld) -> JoltPhysicsBackend {
    let backend = JoltPhysicsBackend()
    let snapshot = buildPhysicsSceneSnapshot(in: world)
    _ = backend.prepare(
        context: PhysicsPrepareContext(
            settings: snapshot.settings,
            deltaTimeSeconds: 0,
            activeBodies: snapshot.bodies,
            activeConstraints: snapshot.constraints,
            syncEvents: []
        )
    )
    return backend
}

func buildPhysicsSceneSnapshot(
    in world: RuntimeWorld,
    settings overrideSettings: PhysicsSettingsResource? = nil
) -> (settings: PhysicsSettingsResource, bodies: [PhysicsBodyDescriptor], constraints: [PhysicsConstraintDescriptor]) {
    var settings = overrideSettings ?? world.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
    settings.backendKind = .jolt

    let entities = world.entities()
    let localTransforms = world.localTransformSnapshot(matching: entities)
    let worldTransforms = world.worldTransformSnapshot(matching: entities)
    let rigidBodies = world.componentSnapshot(RigidBody.self, matching: entities)
    let colliders = world.componentSnapshot(Collider.self, matching: entities)
    let constraints = world.componentSnapshot(Constraint.self, matching: entities)
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

    return (settings, bodies, constraintDescriptors)
}

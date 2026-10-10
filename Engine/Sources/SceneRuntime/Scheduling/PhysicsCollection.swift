import EngineKernel

extension RuntimeWorldSchedule {
    func collectPhysicsBodies(
        from view: RuntimePhysicsReadView
    ) -> (bodies: [PhysicsBodyDescriptor], report: JobDispatchReport) {
        let result = jobSystem.parallelCompactMap(items: view.entities) { entity -> PhysicsBodyDescriptor? in
            let rigidBody = view.rigidBodies[entity]
            let collider = view.colliders[entity]
            guard rigidBody != nil || collider != nil,
                  let localTransform = view.localTransforms[entity],
                  let worldTransform = view.worldTransforms[entity]
            else {
                return nil
            }
            return PhysicsBodyDescriptor(
                entity: entity,
                localTransform: localTransform,
                worldTransform: worldTransform,
                rigidBody: rigidBody,
                collider: collider,
                meshGeometry: view.meshGeometries[entity]
            )
        }
        return (result.0, result.1)
    }

    func collectPhysicsCharacters(from view: RuntimePhysicsReadView) -> [PhysicsCharacterDescriptor] {
        view.entities.compactMap { entity in
            guard let controller = view.characters[entity],
                  let worldTransform = view.worldTransforms[entity] else { return nil }
            return PhysicsCharacterDescriptor(
                entity: entity,
                worldTransform: worldTransform,
                controller: controller
            )
        }
    }

    func collectPhysicsVehicles(from view: RuntimePhysicsReadView) -> [PhysicsVehicleDescriptor] {
        view.entities.compactMap { entity in
            guard let vehicle = view.vehicles[entity], vehicle.isEnabled else { return nil }
            return PhysicsVehicleDescriptor(entity: entity, vehicle: vehicle)
        }
    }

    func collectPhysicsSoftBodies(
        from view: RuntimePhysicsReadView
    ) -> [PhysicsSoftBodyDescriptor] {
        view.entities.compactMap { entity in
            guard let softBody = view.softBodies[entity], softBody.isEnabled,
                  let worldTransform = view.worldTransforms[entity]
            else { return nil }
            let cloth = view.cloths[entity]
            let mesh = view.softBodyMeshes[entity]
            let topology: PhysicsSoftBodyTopology
            switch (cloth, mesh) {
            case let (.some(cloth), .none):
                topology = .cloth(cloth)
            case let (.none, .some(mesh)):
                topology = .surfaceMesh(mesh, view.softBodyMeshGeometries[entity])
            case (.some, .some):
                // A soft body must have exactly one topology provider. Forward
                // the conflict so the native backend reports invalidArgument.
                topology = .invalid
            case (.none, .none):
                return nil
            }
            return PhysicsSoftBodyDescriptor(
                entity: entity,
                worldTransform: worldTransform,
                softBody: softBody,
                topology: topology
            )
        }
    }

    func collectPhysicsConstraints(
        from view: RuntimePhysicsReadView
    ) -> (constraints: [PhysicsConstraintDescriptor], report: JobDispatchReport) {
        let result = jobSystem.parallelCompactMap(items: view.entities) { entity -> PhysicsConstraintDescriptor? in
            guard let constraint = view.constraints[entity],
                  let worldTransform = view.worldTransforms[entity]
            else {
                return nil
            }
            return PhysicsConstraintDescriptor(
                entity: entity,
                worldTransform: worldTransform,
                constraint: constraint
            )
        }
        return (result.0, result.1)
    }

    func diffPhysicsSyncEvents(
        bodies: [PhysicsBodyDescriptor],
        constraints: [PhysicsConstraintDescriptor],
        vehicles: [PhysicsVehicleDescriptor],
        softBodies: [PhysicsSoftBodyDescriptor]
    ) -> (events: [PhysicsSyncEvent], report: JobDispatchReport) {
        let previousBodies = physicsSyncCache.bodies
        let previousConstraints = physicsSyncCache.constraints
        let previousVehicles = physicsSyncCache.vehicles
        let previousSoftBodies = physicsSyncCache.softBodies
        let bodyMap = Dictionary(uniqueKeysWithValues: bodies.map { ($0.entity, $0) })
        let constraintMap = Dictionary(uniqueKeysWithValues: constraints.map { ($0.entity, $0) })
        let vehicleMap = Dictionary(uniqueKeysWithValues: vehicles.map { ($0.entity, $0) })
        let softBodyMap = Dictionary(uniqueKeysWithValues: softBodies.map { ($0.entity, $0) })
        let changedBodyEntities = Set(bodies.compactMap { descriptor in
            previousBodies[descriptor.entity] == descriptor ? nil : descriptor.entity
        })

        let bodyUpserts = jobSystem.parallelCompactMap(items: bodies) { descriptor -> PhysicsSyncEvent? in
            previousBodies[descriptor.entity] == descriptor ? nil : .bodyUpsert(descriptor)
        }
        let bodyRemovals = jobSystem.parallelCompactMap(items: Array(previousBodies.keys)) { entity -> PhysicsSyncEvent? in
            bodyMap[entity] == nil ? .bodyRemove(entity) : nil
        }
        let constraintUpserts = jobSystem.parallelCompactMap(items: constraints) { descriptor -> PhysicsSyncEvent? in
            let dependsOnChangedBody = changedBodyEntities.contains(descriptor.constraint.entityA)
                || changedBodyEntities.contains(descriptor.constraint.entityB)
            return previousConstraints[descriptor.entity] == descriptor && !dependsOnChangedBody
                ? nil
                : .constraintUpsert(descriptor)
        }
        let constraintRemovals = jobSystem.parallelCompactMap(items: Array(previousConstraints.keys)) { entity -> PhysicsSyncEvent? in
            constraintMap[entity] == nil ? .constraintRemove(entity) : nil
        }
        let vehicleUpserts = jobSystem.parallelCompactMap(items: vehicles) { descriptor -> PhysicsSyncEvent? in
            let dependsOnChangedBody = changedBodyEntities.contains(descriptor.entity)
            return previousVehicles[descriptor.entity] == descriptor && !dependsOnChangedBody
                ? nil
                : .vehicleUpsert(descriptor)
        }
        let vehicleRemovals = jobSystem.parallelCompactMap(items: Array(previousVehicles.keys)) { entity -> PhysicsSyncEvent? in
            vehicleMap[entity] == nil ? .vehicleRemove(entity) : nil
        }
        let softBodyUpserts = jobSystem.parallelCompactMap(items: softBodies) { descriptor -> PhysicsSyncEvent? in
            previousSoftBodies[descriptor.entity] == descriptor ? nil : .softBodyUpsert(descriptor)
        }
        let softBodyRemovals = jobSystem.parallelCompactMap(
            items: Array(previousSoftBodies.keys)
        ) { entity -> PhysicsSyncEvent? in
            softBodyMap[entity] == nil ? .softBodyRemove(entity) : nil
        }

        let reports = [bodyUpserts.1, bodyRemovals.1, constraintUpserts.1, constraintRemovals.1,
                       vehicleUpserts.1, vehicleRemovals.1,
                       softBodyUpserts.1, softBodyRemovals.1]
        return (
            bodyUpserts.0 + bodyRemovals.0 + constraintUpserts.0 + constraintRemovals.0
                + vehicleUpserts.0 + vehicleRemovals.0
                + softBodyUpserts.0 + softBodyRemovals.0,
            mergeDispatchReports(reports)
        )
    }

    func mergeWritebacks(
        existing: [PhysicsBodyWriteback],
        incoming: [PhysicsBodyWriteback]
    ) -> [PhysicsBodyWriteback] {
        var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.entity, $0) })
        for writeback in incoming {
            merged[writeback.entity] = writeback
        }
        return Array(merged.values)
    }

    mutating func ensureConfiguredPhysicsBackend(kind: PhysicsBackendKind) {
        guard explicitPhysicsBackend == nil else { return }
        guard resolvedPhysicsBackendKind != kind else { return }

        if usesSharedJoltBackend {
            physicsQueryScene.invalidate()
        }
        physicsBackend.reset()
        switch kind {
        case .none:
            physicsBackend = NullPhysicsBackend()
        case .jolt:
            physicsBackend = joltPhysicsBackend
        }
        resolvedPhysicsBackendKind = kind
        physicsFrameState.backendIdentifier = physicsBackend.identifier
    }

    var usesSharedJoltBackend: Bool {
        guard let backend = physicsBackend as? JoltPhysicsBackend else { return false }
        return backend === joltPhysicsBackend
    }


    func buildPhysicsReadView(in world: RuntimeWorld) -> RuntimePhysicsReadView {
        let entities = world.entities()
        let colliders = world.componentSnapshot(Collider.self, matching: entities)
        let softBodyMeshes = world.componentSnapshot(SoftBodyMesh.self, matching: entities)
        let geometryResource = world.resource(MeshColliderGeometryResource.self)
        var meshGeometries: [EntityID: MeshColliderGeometry] = [:]
        for (entity, collider) in colliders {
            let resourceID = collider.shape.resourceID
            if let geometry = geometryResource?.geometry(for: resourceID) {
                meshGeometries[entity] = geometry
            }
        }
        var softBodyMeshGeometries: [EntityID: MeshColliderGeometry] = [:]
        for (entity, mesh) in softBodyMeshes {
            if let geometry = geometryResource?.geometry(for: mesh.resourceID) {
                softBodyMeshGeometries[entity] = geometry
            }
        }
        return RuntimePhysicsReadView(
            entities: entities,
            localTransforms: world.localTransformSnapshot(matching: entities),
            worldTransforms: world.worldTransformSnapshot(matching: entities),
            rigidBodies: world.componentSnapshot(RigidBody.self, matching: entities),
            colliders: colliders,
            constraints: world.componentSnapshot(Constraint.self, matching: entities),
            characters: world.componentSnapshot(CharacterController.self, matching: entities),
            vehicles: world.componentSnapshot(Vehicle.self, matching: entities),
            softBodies: world.componentSnapshot(SoftBody.self, matching: entities),
            cloths: world.componentSnapshot(Cloth.self, matching: entities),
            softBodyMeshes: softBodyMeshes,
            meshGeometries: meshGeometries,
            softBodyMeshGeometries: softBodyMeshGeometries
        )
    }
}

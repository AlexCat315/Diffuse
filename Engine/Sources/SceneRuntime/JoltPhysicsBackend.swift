import CJoltBridge
import SIMDCompat

public final class JoltPhysicsBackend: PhysicsBackend, @unchecked Sendable {
    private static let expectedABIVersion: UInt32 = 4
    private static let colliderHasBoxFlag: UInt32 = 1 << 0
    private static let colliderHasSphereFlag: UInt32 = 1 << 1
    private static let colliderHasMeshFlag: UInt32 = 1 << 2
    private static let colliderIsTriggerFlag: UInt32 = 1 << 3
    private static let rigidBodyAllowSleepFlag: UInt32 = 1 << 4
    private static let colliderHasCapsuleFlag: UInt32 = 1 << 5
    private static let colliderHasConvexFlag: UInt32 = 1 << 6
    private static let rigidBodyContinuousCollisionFlag: UInt32 = 1 << 7
    private static let colliderHasCylinderFlag: UInt32 = 1 << 8
    private static let queryShapeBox: UInt8 = 0
    private static let queryShapeSphere: UInt8 = 1
    private static let queryShapeCapsule: UInt8 = 2

    private var context: GuavaJoltContext?
    private var lastPreparedBodyCount: Int = 0
    private var initializationError: PhysicsBackendError?
    private var meshRevisionByEntity: [EntityID: UInt64] = [:]
    private var activeCapacity: PhysicsCapacitySettings?

    public init() {
        var layout = GuavaJoltABILayout()
        var vehicleLayout = GuavaJoltVehicleABILayout()
        vehicleLayout.struct_size = UInt32(MemoryLayout<GuavaJoltVehicleABILayout>.size)
        let compatible = guava_jolt_bridge_abi_version() == Self.expectedABIVersion
            && guava_jolt_bridge_get_abi_layout(&layout)
            && layout.abi_version == Self.expectedABIVersion
            && layout.struct_size == UInt32(MemoryLayout<GuavaJoltABILayout>.size)
            && layout.body_desc_size == UInt32(MemoryLayout<GuavaJoltBodyDesc>.size)
            && layout.constraint_desc_size == UInt32(MemoryLayout<GuavaJoltConstraintDesc>.size)
            && layout.step_config_size == UInt32(MemoryLayout<GuavaJoltStepConfig>.size)
            && layout.body_state_size == UInt32(MemoryLayout<GuavaJoltBodyState>.size)
            && layout.contact_event_size == UInt32(MemoryLayout<GuavaJoltContactEvent>.size)
            && layout.character_desc_size == UInt32(MemoryLayout<GuavaJoltCharacterDesc>.size)
            && layout.character_command_size == UInt32(MemoryLayout<GuavaJoltCharacterCommand>.size)
            && layout.character_state_size == UInt32(MemoryLayout<GuavaJoltCharacterState>.size)
            && layout.shape_instance_size == UInt32(MemoryLayout<GuavaJoltShapeInstance>.size)
            && layout.joint_break_event_size == UInt32(MemoryLayout<GuavaJoltJointBreakEvent>.size)
            && layout.context_config_size == UInt32(MemoryLayout<GuavaJoltContextConfig>.size)
            && layout.soft_body_desc_size == UInt32(MemoryLayout<GuavaJoltSoftBodyDesc>.size)
            && layout.soft_body_state_size == UInt32(MemoryLayout<GuavaJoltSoftBodyState>.size)
            && layout.soft_body_sync_stats_size == UInt32(MemoryLayout<GuavaJoltSoftBodySyncStats>.size)
            && guava_jolt_bridge_get_vehicle_abi_layout(&vehicleLayout)
            && vehicleLayout.abi_version == Self.expectedABIVersion
            && vehicleLayout.vehicle_desc_size == UInt32(MemoryLayout<GuavaJoltVehicleDesc>.size)
            && vehicleLayout.wheel_desc_size == UInt32(MemoryLayout<GuavaJoltVehicleWheelDesc>.size)
            && vehicleLayout.differential_desc_size == UInt32(MemoryLayout<GuavaJoltVehicleDifferentialDesc>.size)
            && vehicleLayout.anti_roll_bar_desc_size == UInt32(MemoryLayout<GuavaJoltVehicleAntiRollBarDesc>.size)
            && vehicleLayout.track_desc_size == UInt32(MemoryLayout<GuavaJoltVehicleTrackDesc>.size)
            && vehicleLayout.command_size == UInt32(MemoryLayout<GuavaJoltVehicleCommand>.size)
            && vehicleLayout.state_size == UInt32(MemoryLayout<GuavaJoltVehicleState>.size)
            && vehicleLayout.wheel_state_size == UInt32(MemoryLayout<GuavaJoltVehicleWheelState>.size)
            && vehicleLayout.sync_stats_size == UInt32(MemoryLayout<GuavaJoltVehicleSyncStats>.size)
        if !compatible {
            initializationError = PhysicsBackendError(
                code: .abiMismatch,
                message: "CJoltBridge ABI layout does not match the Swift bindings"
            )
        }
    }

    deinit {
        if let context {
            guava_jolt_context_destroy(context)
        }
    }

    public var identifier: String {
        "jolt"
    }

    public func prepare(context: PhysicsPrepareContext) -> PhysicsPrepareResult {
        let rebuiltContext = ensureNativeContext(capacity: context.settings.capacity)
        guard let nativeContext = self.context else {
            lastPreparedBodyCount = context.activeBodies.count + context.activeSoftBodies.count
            return PhysicsPrepareResult(
                synchronizedBodies: context.activeBodies.count,
                synchronizedConstraints: context.activeConstraints.count,
                error: initializationError
            )
        }

        let usesFullSnapshot = context.isFullSnapshot
        var bodyUpserts: [PhysicsBodyDescriptor] = []
        var bodyRemovals: [UInt64] = []
        var constraintUpserts: [PhysicsConstraintDescriptor] = []
        var constraintRemovals: [UInt64] = []
        var vehicleUpserts: [PhysicsVehicleDescriptor] = []
        var vehicleRemovals: [UInt64] = []
        var softBodyUpserts: [PhysicsSoftBodyDescriptor] = []
        var softBodyRemovals: [UInt64] = []
        if usesFullSnapshot || rebuiltContext {
            bodyUpserts = context.activeBodies
            constraintUpserts = context.activeConstraints
            vehicleUpserts = context.activeVehicles
            softBodyUpserts = context.activeSoftBodies
        } else {
            for event in context.syncEvents {
                switch event {
                case let .bodyUpsert(descriptor): bodyUpserts.append(descriptor)
                case let .bodyRemove(entity): bodyRemovals.append(entity.rawValue)
                case let .constraintUpsert(descriptor): constraintUpserts.append(descriptor)
                case let .constraintRemove(entity): constraintRemovals.append(entity.rawValue)
                case let .vehicleUpsert(descriptor): vehicleUpserts.append(descriptor)
                case let .vehicleRemove(entity): vehicleRemovals.append(entity.rawValue)
                case let .softBodyUpsert(descriptor): softBodyUpserts.append(descriptor)
                case let .softBodyRemove(entity): softBodyRemovals.append(entity.rawValue)
                }
            }
        }
        bodyUpserts.sort { $0.entity.rawValue < $1.entity.rawValue }
        bodyRemovals.sort()
        constraintUpserts.sort { $0.entity.rawValue < $1.entity.rawValue }
        constraintRemovals.sort()
        vehicleUpserts.sort { $0.entity.rawValue < $1.entity.rawValue }
        vehicleRemovals.sort()
        softBodyUpserts.sort { $0.entity.rawValue < $1.entity.rawValue }
        softBodyRemovals.sort()

        var bodyDescs = bodyUpserts.map(makeBodyDesc)
        let constraintDescs = constraintUpserts.map(makeConstraintDesc)
        let shapeInstancesByBody = bodyUpserts.map(makeShapeInstances)
        let flatShapeInstances = shapeInstancesByBody.flatMap { $0 }
        lastPreparedBodyCount = context.activeBodies.count + context.activeSoftBodies.count

        // Collect mesh geometry into flat arrays so C pointers stay valid.
        var flatVertices: [Float] = []
        var flatIndices: [UInt32] = []
        var meshDescs: [GuavaJoltMeshGeometry] = []
        meshDescs.reserveCapacity(bodyUpserts.count)
        let activeEntities = Set(context.activeBodies.map(\.entity))
        meshRevisionByEntity = meshRevisionByEntity.filter { activeEntities.contains($0.key) }
        for descriptor in bodyUpserts {
            guard let geometry = descriptor.meshGeometry,
                  geometry.triangleCount > 0,
                  !geometry.positions.isEmpty else {
                continue
            }
            guard meshRevisionByEntity[descriptor.entity] != geometry.revision else {
                continue
            }
            meshRevisionByEntity[descriptor.entity] = geometry.revision
            var desc = GuavaJoltMeshGeometry()
            desc.entity_id = descriptor.entity.rawValue
            desc.geometry_revision = geometry.revision
            desc.vertex_count = UInt32(geometry.positions.count)
            desc.index_count = UInt32(geometry.triangleIndices.count)
            meshDescs.append(desc)
            for position in geometry.positions {
                flatVertices.append(position.x)
                flatVertices.append(position.y)
                flatVertices.append(position.z)
            }
            flatIndices.append(contentsOf: geometry.triangleIndices)
        }

        var stats = GuavaJoltPrepareStats()
        let success = flatVertices.withUnsafeBufferPointer { vertexBuffer in
            flatIndices.withUnsafeBufferPointer { indexBuffer in
                flatShapeInstances.withUnsafeBufferPointer { shapeBuffer in
                    bodyDescs.withUnsafeMutableBufferPointer { bodyBuffer in
                        var shapeCursor = 0
                        for index in bodyBuffer.indices {
                            let count = shapeInstancesByBody[index].count
                            bodyBuffer[index].shape_instances = count > 0
                                ? shapeBuffer.baseAddress?.advanced(by: shapeCursor)
                                : nil
                            bodyBuffer[index].shape_instance_count = UInt32(count)
                            shapeCursor += count
                        }
                        return constraintDescs.withUnsafeBufferPointer { constraintBuffer in
                            meshDescs.withUnsafeMutableBufferPointer { meshBuffer in
                                var vertexCursor = 0
                                var indexCursor = 0
                                for index in meshBuffer.indices {
                                    meshBuffer[index].vertices = vertexBuffer.baseAddress?.advanced(by: vertexCursor)
                                    meshBuffer[index].indices = indexBuffer.baseAddress?.advanced(by: indexCursor)
                                    vertexCursor += Int(meshBuffer[index].vertex_count) * 3
                                    indexCursor += Int(meshBuffer[index].index_count)
                                }
                                return bodyRemovals.withUnsafeBufferPointer { bodyRemovalBuffer in
                                    constraintRemovals.withUnsafeBufferPointer { constraintRemovalBuffer in
                                        if usesFullSnapshot {
                                            return guava_jolt_context_prepare_with_meshes(
                                                nativeContext,
                                                bodyBuffer.baseAddress,
                                                bodyBuffer.count,
                                                constraintBuffer.baseAddress,
                                                constraintBuffer.count,
                                                meshBuffer.baseAddress,
                                                meshBuffer.count,
                                                &stats
                                            )
                                        }
                                        return guava_jolt_context_apply_sync_events(
                                            nativeContext,
                                            bodyBuffer.baseAddress,
                                            bodyBuffer.count,
                                            bodyRemovalBuffer.baseAddress,
                                            bodyRemovalBuffer.count,
                                            constraintBuffer.baseAddress,
                                            constraintBuffer.count,
                                            constraintRemovalBuffer.baseAddress,
                                            constraintRemovalBuffer.count,
                                            meshBuffer.baseAddress,
                                            meshBuffer.count,
                                            &stats
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        guard success else {
            return PhysicsPrepareResult(
                synchronizedBodies: 0,
                synchronizedConstraints: 0,
                error: nativeError(from: nativeContext)
            )
        }

        let characterDescs = context.activeCharacters.map(makeCharacterDesc)
        let synchronizedCharacters = characterDescs.withUnsafeBufferPointer { buffer in
            guava_jolt_context_sync_characters(nativeContext, buffer.baseAddress, buffer.count)
        }
        guard synchronizedCharacters else {
            return PhysicsPrepareResult(
                synchronizedBodies: Int(stats.synchronized_bodies),
                synchronizedConstraints: Int(stats.synchronized_constraints),
                removedBodies: Int(stats.removed_bodies),
                removedConstraints: Int(stats.removed_constraints),
                error: nativeError(from: nativeContext)
            )
        }

        let vehicleSync = synchronizeVehicles(
            upserts: vehicleUpserts,
            removals: vehicleRemovals,
            fullSnapshot: usesFullSnapshot || rebuiltContext,
            nativeContext: nativeContext
        )
        guard vehicleSync.success else {
            return PhysicsPrepareResult(
                synchronizedBodies: Int(stats.synchronized_bodies),
                synchronizedConstraints: Int(stats.synchronized_constraints),
                removedBodies: Int(stats.removed_bodies),
                removedConstraints: Int(stats.removed_constraints),
                synchronizedVehicles: Int(vehicleSync.stats.synchronized_vehicles),
                removedVehicles: Int(vehicleSync.stats.removed_vehicles),
                error: nativeError(from: nativeContext)
            )
        }

        let softBodySync = synchronizeSoftBodies(
            upserts: softBodyUpserts,
            removals: softBodyRemovals,
            fullSnapshot: usesFullSnapshot || rebuiltContext,
            nativeContext: nativeContext
        )
        guard softBodySync.success else {
            return PhysicsPrepareResult(
                synchronizedBodies: Int(stats.synchronized_bodies),
                synchronizedConstraints: Int(stats.synchronized_constraints),
                removedBodies: Int(stats.removed_bodies),
                removedConstraints: Int(stats.removed_constraints),
                synchronizedVehicles: Int(vehicleSync.stats.synchronized_vehicles),
                removedVehicles: Int(vehicleSync.stats.removed_vehicles),
                synchronizedSoftBodies: Int(softBodySync.stats.synchronized_soft_bodies),
                removedSoftBodies: Int(softBodySync.stats.removed_soft_bodies),
                error: nativeError(from: nativeContext)
            )
        }

        return PhysicsPrepareResult(
            synchronizedBodies: Int(stats.synchronized_bodies),
            synchronizedConstraints: Int(stats.synchronized_constraints),
            removedBodies: Int(stats.removed_bodies),
            removedConstraints: Int(stats.removed_constraints),
            synchronizedVehicles: Int(vehicleSync.stats.synchronized_vehicles),
            removedVehicles: Int(vehicleSync.stats.removed_vehicles),
            synchronizedSoftBodies: Int(softBodySync.stats.synchronized_soft_bodies),
            removedSoftBodies: Int(softBodySync.stats.removed_soft_bodies)
        )
    }

    public func step(context: PhysicsStepContext) -> PhysicsStepResult {
        guard let nativeContext = self.context else {
            return PhysicsStepResult(
                bodyCount: context.activeBodies.count,
                constraintCount: context.activeConstraints.count,
                contactCount: 0,
                writebacks: [],
                error: initializationError
            )
        }

        var bodyStates = context.activeBodies.map(makeBodyState)
        var config = GuavaJoltStepConfig(
            delta_seconds: Float(context.stepDeltaSeconds),
            gravity_x: context.settings.gravity.x,
            gravity_y: context.settings.gravity.y,
            gravity_z: context.settings.gravity.z,
            collision_steps: UInt32(max(1, context.settings.collisionSteps)),
            allow_sleep: context.settings.allowSleep ? 1 : 0,
            reserved0: 0,
            reserved1: 0
        )
        var stats = GuavaJoltStepStats()
        let vehicleCommandDescs = context.vehicleCommands
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { makeVehicleCommand(entity: $0.key, command: $0.value) }
        let vehicleCommandsAccepted = vehicleCommandDescs.withUnsafeBufferPointer { buffer in
            guava_jolt_context_set_vehicle_commands(
                nativeContext, buffer.baseAddress, buffer.count
            )
        }
        guard vehicleCommandsAccepted else {
            return PhysicsStepResult(
                bodyCount: context.activeBodies.count,
                constraintCount: context.activeConstraints.count,
                error: nativeError(from: nativeContext)
            )
        }
        let commandDescs = context.characterCommands
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { makeCharacterCommand(entity: $0.key, command: $0.value) }
        var characterStates = [GuavaJoltCharacterState](
            repeating: GuavaJoltCharacterState(),
            count: context.activeCharacters.count
        )
        let characterStateCount = commandDescs.withUnsafeBufferPointer { commandBuffer in
            characterStates.withUnsafeMutableBufferPointer { stateBuffer in
                guava_jolt_context_step_characters(
                    nativeContext,
                    &config,
                    commandBuffer.baseAddress,
                    commandBuffer.count,
                    stateBuffer.baseAddress,
                    stateBuffer.count
                )
            }
        }
        let descriptorsByEntity = Dictionary(uniqueKeysWithValues: context.activeBodies.map { ($0.entity.rawValue, $0) })
        let success = bodyStates.withUnsafeMutableBufferPointer { stateBuffer in
            guava_jolt_context_step(
                nativeContext,
                &config,
                stateBuffer.baseAddress,
                stateBuffer.count,
                &stats
            )
        }

        guard success else {
            return PhysicsStepResult(
                bodyCount: context.activeBodies.count,
                constraintCount: context.activeConstraints.count,
                contactCount: 0,
                writebacks: [],
                error: nativeError(from: nativeContext)
            )
        }

        let contactEvents = copyContactEvents(
            from: nativeContext,
            expectedCount: Int(stats.contact_count)
        )
        var nativeBreakEvents = [GuavaJoltJointBreakEvent](
            repeating: GuavaJoltJointBreakEvent(),
            count: context.activeConstraints.count
        )
        let breakEventCount = nativeBreakEvents.withUnsafeMutableBufferPointer { buffer in
            guava_jolt_context_drain_joint_break_events(
                nativeContext,
                buffer.baseAddress,
                buffer.count
            )
        }
        let jointBreakEvents = nativeBreakEvents
            .prefix(min(Int(breakEventCount), nativeBreakEvents.count))
            .map {
                PhysicsJointBreakEvent(
                    jointEntity: EntityID(rawValue: $0.joint_entity),
                    entityA: EntityID(rawValue: $0.entity_a),
                    entityB: EntityID(rawValue: $0.entity_b),
                    force: $0.force,
                    torque: $0.torque
                )
            }
        var nativeVehicleStates = [GuavaJoltVehicleState](
            repeating: GuavaJoltVehicleState(), count: context.activeVehicles.count
        )
        let wheelCapacity = context.activeVehicles.reduce(0) { partial, descriptor in
            partial + descriptor.vehicle.wheels.count
        }
        var nativeWheelStates = [GuavaJoltVehicleWheelState](
            repeating: GuavaJoltVehicleWheelState(), count: wheelCapacity
        )
        var nativeWheelStateCount: UInt32 = 0
        let nativeVehicleStateCount = nativeVehicleStates.withUnsafeMutableBufferPointer { stateBuffer in
            nativeWheelStates.withUnsafeMutableBufferPointer { wheelBuffer in
                guava_jolt_context_copy_vehicle_states(
                    nativeContext,
                    stateBuffer.baseAddress,
                    stateBuffer.count,
                    wheelBuffer.baseAddress,
                    wheelBuffer.count,
                    &nativeWheelStateCount
                )
            }
        }
        let copiedWheelStates = Array(nativeWheelStates.prefix(
            min(Int(nativeWheelStateCount), nativeWheelStates.count)
        ))
        guard let softBodyStates = copySoftBodyStates(
            from: nativeContext,
            descriptors: context.activeSoftBodies
        ) else {
            return PhysicsStepResult(
                bodyCount: Int(stats.body_count),
                constraintCount: Int(stats.constraint_count),
                contactCount: max(Int(stats.contact_count), contactEvents.count),
                error: nativeError(from: nativeContext)
            )
        }
        return PhysicsStepResult(
            bodyCount: Int(stats.body_count),
            constraintCount: Int(stats.constraint_count),
            contactCount: max(Int(stats.contact_count), contactEvents.count),
            writebacks: bodyStates
                .prefix(Int(stats.state_count))
                .compactMap { makeWriteback(from: $0, descriptorsByEntity: descriptorsByEntity) },
            contactEvents: contactEvents,
            jointBreakEvents: jointBreakEvents,
            characterStates: characterStates
                .prefix(min(Int(characterStateCount), characterStates.count))
                .map(makeCharacterState),
            vehicleStates: nativeVehicleStates
                .prefix(min(Int(nativeVehicleStateCount), nativeVehicleStates.count))
                .map { makeVehicleState($0, wheelStates: copiedWheelStates) },
            softBodyStates: softBodyStates
        )
    }

    public func raycast(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter) -> PhysicsRaycastHit? {
        if filter.excludedEntities.count > 1 {
            return raycastAll(query, filter: filter, maxHits: .max).first
        }
        guard let nativeContext = context else { return nil }
        var cQuery = GuavaJoltRaycastQuery(
            origin_x: query.origin.x,
            origin_y: query.origin.y,
            origin_z: query.origin.z,
            direction_x: query.direction.x,
            direction_y: query.direction.y,
            direction_z: query.direction.z,
            max_distance: query.maxDistance
        )
        var cFilter = makeQueryFilter(filter)
        var hit = GuavaJoltRaycastHit()
        let success = guava_jolt_context_raycast(nativeContext, &cQuery, &cFilter, &hit)
        guard success else { return nil }
        return makeRaycastHit(hit)
    }

    public func raycastAll(
        _ query: PhysicsRaycastQuery,
        filter: PhysicsQueryFilter,
        maxHits: Int
    ) -> [PhysicsRaycastHit] {
        guard let nativeContext = context, maxHits > 0 else { return [] }
        var cQuery = GuavaJoltRaycastQuery(
            origin_x: query.origin.x, origin_y: query.origin.y, origin_z: query.origin.z,
            direction_x: query.direction.x, direction_y: query.direction.y, direction_z: query.direction.z,
            max_distance: query.maxDistance
        )
        var cFilter = makeQueryFilter(filter)
        let capacity = maxHits == .max || filter.excludedEntities.count > 1
            ? max(1, lastPreparedBodyCount * 64)
            : maxHits
        var hits = [GuavaJoltRaycastHit](repeating: GuavaJoltRaycastHit(), count: capacity)
        let count = hits.withUnsafeMutableBufferPointer { buffer in
            guava_jolt_context_raycast_all(
                nativeContext, &cQuery, &cFilter, buffer.baseAddress, buffer.count)
        }
        return hits.prefix(min(Int(count), capacity))
            .map(makeRaycastHit)
            .filter { !filter.excludedEntities.contains($0.entity) }
            .prefix(maxHits)
            .map { $0 }
    }

    public func overlapAABB(_ query: PhysicsOverlapAABBQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit] {
        guard let nativeContext = context else { return [] }
        let requestedMaxResults = query.maxResults == .max
            ? UInt32.max
            : UInt32(max(0, min(query.maxResults, Int(UInt32.max))))
        let maxResults = filter.excludedEntities.count > 1 ? UInt32.max : requestedMaxResults
        guard maxResults > 0 else { return [] }

        var cQuery = GuavaJoltOverlapAABBQuery(
            bounds_min_x: query.bounds.min.x,
            bounds_min_y: query.bounds.min.y,
            bounds_min_z: query.bounds.min.z,
            bounds_max_x: query.bounds.max.x,
            bounds_max_y: query.bounds.max.y,
            bounds_max_z: query.bounds.max.z,
            max_results: maxResults
        )
        var cFilter = makeQueryFilter(filter)
        let capacity = maxResults == UInt32.max
            ? lastPreparedBodyCount
            : min(Int(maxResults), lastPreparedBodyCount)
        guard capacity > 0 else { return [] }
        var hits = [GuavaJoltOverlapHit](repeating: GuavaJoltOverlapHit(), count: capacity)
        let count = hits.withUnsafeMutableBufferPointer { buffer in
            guava_jolt_context_overlap_aabb(
                nativeContext,
                &cQuery,
                &cFilter,
                buffer.baseAddress,
                buffer.count
            )
        }
        return hits.prefix(min(Int(count), hits.count))
            .map(makeOverlapHit)
            .filter { !filter.excludedEntities.contains($0.entity) }
            .prefix(Int(requestedMaxResults))
            .map { $0 }
    }

    public func overlapShape(_ query: PhysicsOverlapShapeQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit] {
        guard let nativeContext = context else { return [] }
        let requestedMaxResults = query.maxResults == .max
            ? UInt32.max
            : UInt32(max(0, min(query.maxResults, Int(UInt32.max))))
        let maxResults = filter.excludedEntities.count > 1 ? UInt32.max : requestedMaxResults
        guard maxResults > 0 else { return [] }

        var cQuery = makeOverlapShapeQuery(query, maxResults: maxResults)
        var cFilter = makeQueryFilter(filter)
        let capacity = maxResults == UInt32.max
            ? lastPreparedBodyCount
            : min(Int(maxResults), lastPreparedBodyCount)
        guard capacity > 0 else { return [] }
        var hits = [GuavaJoltOverlapHit](repeating: GuavaJoltOverlapHit(), count: capacity)
        let count = hits.withUnsafeMutableBufferPointer { buffer in
            guava_jolt_context_overlap_shape(
                nativeContext,
                &cQuery,
                &cFilter,
                buffer.baseAddress,
                buffer.count
            )
        }
        return hits.prefix(min(Int(count), hits.count))
            .map(makeOverlapHit)
            .filter { !filter.excludedEntities.contains($0.entity) }
            .prefix(Int(requestedMaxResults))
            .map { $0 }
    }

    public func sweepAABB(_ query: PhysicsSweepAABBQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit? {
        if filter.excludedEntities.count > 1 {
            // The v2 shape cast collector is also used for a box AABB batch so
            // multiple exclusions cannot accidentally hide a later valid hit.
            let center = (query.bounds.min + query.bounds.max) * 0.5
            let halfExtents = (query.bounds.max - query.bounds.min) * 0.5
            return sweepShapeAll(
                PhysicsSweepShapeQuery(
                    shape: .box(halfExtents: halfExtents),
                    position: center,
                    translation: query.translation
                ),
                filter: filter,
                maxHits: .max
            ).first
        }
        guard let nativeContext = context else { return nil }
        var cQuery = GuavaJoltSweepAABBQuery(
            bounds_min_x: query.bounds.min.x,
            bounds_min_y: query.bounds.min.y,
            bounds_min_z: query.bounds.min.z,
            bounds_max_x: query.bounds.max.x,
            bounds_max_y: query.bounds.max.y,
            bounds_max_z: query.bounds.max.z,
            translation_x: query.translation.x,
            translation_y: query.translation.y,
            translation_z: query.translation.z
        )
        var cFilter = makeQueryFilter(filter)
        var hit = GuavaJoltSweepHit()
        let success = guava_jolt_context_sweep_aabb(nativeContext, &cQuery, &cFilter, &hit)
        guard success else { return nil }
        return makeSweepHit(hit)
    }

    public func sweepShape(_ query: PhysicsSweepShapeQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit? {
        if filter.excludedEntities.count > 1 {
            return sweepShapeAll(query, filter: filter, maxHits: .max).first
        }
        guard let nativeContext = context else { return nil }
        var cQuery = makeSweepShapeQuery(query)
        var cFilter = makeQueryFilter(filter)
        var hit = GuavaJoltSweepHit()
        let success = guava_jolt_context_sweep_shape(nativeContext, &cQuery, &cFilter, &hit)
        guard success else { return nil }
        return makeSweepHit(hit)
    }

    public func sweepShapeAll(
        _ query: PhysicsSweepShapeQuery,
        filter: PhysicsQueryFilter,
        maxHits: Int
    ) -> [PhysicsSweepHit] {
        guard let nativeContext = context, maxHits > 0 else { return [] }
        var cQuery = makeSweepShapeQuery(query)
        var cFilter = makeQueryFilter(filter)
        let capacity = maxHits == .max || filter.excludedEntities.count > 1
            ? max(1, lastPreparedBodyCount * 64)
            : maxHits
        var hits = [GuavaJoltSweepHit](repeating: GuavaJoltSweepHit(), count: capacity)
        let count = hits.withUnsafeMutableBufferPointer { buffer in
            guava_jolt_context_sweep_shape_all(
                nativeContext, &cQuery, &cFilter, buffer.baseAddress, buffer.count)
        }
        return hits.prefix(min(Int(count), capacity))
            .map(makeSweepHit)
            .filter { !filter.excludedEntities.contains($0.entity) }
            .prefix(maxHits)
            .map { $0 }
    }

    public func detectTriggerFrame(maxEventCount: Int) -> TriggerFrameResource {
        guard let nativeContext = context else { return TriggerFrameResource() }
        let capacity = max(maxEventCount, lastPreparedBodyCount * max(1, lastPreparedBodyCount) * 3)
        guard capacity > 0 else { return TriggerFrameResource() }
        var events = [GuavaJoltTriggerEvent](repeating: GuavaJoltTriggerEvent(), count: capacity)
        let count = events.withUnsafeMutableBufferPointer { buffer in
            guava_jolt_context_detect_triggers(nativeContext, buffer.baseAddress, buffer.count)
        }

        var enters: [TriggerEvent] = []
        var exits: [TriggerEvent] = []
        var active: [TriggerEvent] = []
        for event in events.prefix(min(Int(count), events.count)) {
            let trigger = EntityID(rawValue: event.trigger_entity)
            let other = EntityID(rawValue: event.other_entity)
            switch event.kind {
            case 0:
                enters.append(TriggerEvent(triggerEntity: trigger, otherEntity: other, kind: .enter))
            case 1:
                exits.append(TriggerEvent(triggerEntity: trigger, otherEntity: other, kind: .exit))
            case 2:
                active.append(TriggerEvent(triggerEntity: trigger, otherEntity: other, kind: .active))
            default:
                continue
            }
        }
        return TriggerFrameResource(enters: enters, exits: exits, active: active)
    }

    public func reset() {
        if let context {
            guava_jolt_context_reset(context)
        }
        lastPreparedBodyCount = 0
        meshRevisionByEntity.removeAll(keepingCapacity: true)
    }

    @discardableResult
    private func ensureNativeContext(capacity: PhysicsCapacitySettings) -> Bool {
        guard initializationError?.code != .abiMismatch else { return false }
        let capacity = PhysicsCapacitySettings(
            maxBodies: capacity.maxBodies,
            bodyMutexCount: capacity.bodyMutexCount,
            maxBodyPairs: capacity.maxBodyPairs,
            maxContactConstraints: capacity.maxContactConstraints,
            tempAllocatorBytes: capacity.tempAllocatorBytes,
            workerThreadCount: capacity.workerThreadCount
        )
        guard context == nil || activeCapacity != capacity else { return false }

        if let context {
            guava_jolt_context_destroy(context)
            self.context = nil
        }
        lastPreparedBodyCount = 0
        meshRevisionByEntity.removeAll(keepingCapacity: true)

        var config = GuavaJoltContextConfig()
        config.struct_size = UInt32(MemoryLayout<GuavaJoltContextConfig>.size)
        config.max_bodies = UInt32(capacity.maxBodies)
        config.body_mutex_count = UInt32(capacity.bodyMutexCount)
        config.max_body_pairs = UInt32(capacity.maxBodyPairs)
        config.max_contact_constraints = UInt32(capacity.maxContactConstraints)
        config.worker_thread_count = UInt32(capacity.workerThreadCount)
        config.temp_allocator_bytes = UInt64(capacity.tempAllocatorBytes)
        guard let newContext = guava_jolt_context_create_with_config(&config) else {
            activeCapacity = nil
            initializationError = PhysicsBackendError(
                code: .invalidArgument,
                message: "Jolt context capacity configuration is invalid"
            )
            return false
        }
        context = newContext
        activeCapacity = capacity
        initializationError = nil
        return true
    }

    private func nativeError(from context: GuavaJoltContext) -> PhysicsBackendError {
        switch guava_jolt_context_last_error(context) {
        case 1:
            return PhysicsBackendError(code: .abiMismatch, message: "CJoltBridge ABI mismatch")
        case 2:
            return PhysicsBackendError(code: .invalidArgument, message: "CJoltBridge received an invalid argument")
        case 3:
            return PhysicsBackendError(code: .invalidShape, message: "Collider shape could not be created")
        case 4:
            return PhysicsBackendError(code: .bodyCreationFailed, message: "Jolt failed to create a body")
        case 5:
            return PhysicsBackendError(code: .updateFailed, message: "Jolt simulation update failed")
        default:
            return PhysicsBackendError(code: .unknown, message: "Unknown CJoltBridge failure")
        }
    }

    private func allocateNativeBuffer<Element>(
        copying values: [Element]
    ) -> UnsafeMutablePointer<Element> {
        let storage = UnsafeMutablePointer<Element>.allocate(capacity: max(1, values.count))
        if !values.isEmpty {
            values.withUnsafeBufferPointer { source in
                storage.initialize(from: source.baseAddress!, count: source.count)
            }
        }
        return storage
    }

    private func deallocateNativeBuffer<Element>(
        _ storage: UnsafeMutablePointer<Element>,
        count: Int
    ) {
        if count > 0 { storage.deinitialize(count: count) }
        storage.deallocate()
    }

    private func synchronizeSoftBodies(
        upserts: [PhysicsSoftBodyDescriptor],
        removals: [UInt64],
        fullSnapshot: Bool,
        nativeContext: GuavaJoltContext
    ) -> (success: Bool, stats: GuavaJoltSoftBodySyncStats) {
        var descriptors = upserts.map(makeSoftBodyDesc)
        let fixedVerticesByBody = upserts.map {
            $0.cloth.fixedVertexIndices.map(UInt32.init(clamping:))
        }
        let flatFixedVertices = fixedVerticesByBody.flatMap { $0 }
        var stats = GuavaJoltSoftBodySyncStats()
        let success = flatFixedVertices.withUnsafeBufferPointer { fixedBuffer in
            descriptors.withUnsafeMutableBufferPointer { descriptorBuffer in
                var fixedOffset = 0
                for index in descriptorBuffer.indices {
                    let count = fixedVerticesByBody[index].count
                    descriptorBuffer[index].fixed_vertices = count > 0
                        ? fixedBuffer.baseAddress?.advanced(by: fixedOffset)
                        : nil
                    fixedOffset += count
                }
                return removals.withUnsafeBufferPointer { removalBuffer in
                    guava_jolt_context_sync_soft_bodies(
                        nativeContext,
                        descriptorBuffer.baseAddress,
                        descriptorBuffer.count,
                        removalBuffer.baseAddress,
                        removalBuffer.count,
                        fullSnapshot,
                        &stats
                    )
                }
            }
        }
        return (success, stats)
    }

    private func makeSoftBodyDesc(
        _ descriptor: PhysicsSoftBodyDescriptor
    ) -> GuavaJoltSoftBodyDesc {
        let rotation = rotationQuaternion(from: descriptor.worldTransform.matrix)
        let body = descriptor.softBody
        let cloth = descriptor.cloth
        var result = GuavaJoltSoftBodyDesc()
        result.entity_id = descriptor.entity.rawValue
        result.position_x = descriptor.worldTransform.translation.x
        result.position_y = descriptor.worldTransform.translation.y
        result.position_z = descriptor.worldTransform.translation.z
        result.rotation_x = rotation.vector.x
        result.rotation_y = rotation.vector.y
        result.rotation_z = rotation.vector.z
        result.rotation_w = rotation.vector.w
        result.grid_size_x = UInt32(clamping: cloth.gridSizeX)
        result.grid_size_z = UInt32(clamping: cloth.gridSizeZ)
        result.spacing = cloth.spacing
        result.fixed_vertex_count = UInt32(clamping: cloth.fixedVertexIndices.count)
        result.bend_type = cloth.bendType.rawValue
        result.allow_sleep = body.allowSleep ? 1 : 0
        result.faces_double_sided = body.facesDoubleSided ? 1 : 0
        result.self_collision = body.selfCollision ? 1 : 0
        result.vertex_mass = body.vertexMass
        result.compliance = cloth.compliance
        result.shear_compliance = cloth.shearCompliance
        result.bend_compliance = cloth.bendCompliance
        result.pressure = body.pressure
        result.linear_damping = body.linearDamping
        result.friction = body.friction
        result.restitution = body.restitution
        result.gravity_factor = body.gravityScale
        result.vertex_radius = body.vertexRadius
        result.max_linear_velocity = body.maxLinearVelocity
        result.solver_iterations = UInt32(clamping: body.solverIterations)
        result.layer_id = body.layerID
        result.layer_mask = body.layerMask
        return result
    }

    private func copySoftBodyStates(
        from nativeContext: GuavaJoltContext,
        descriptors: [PhysicsSoftBodyDescriptor]
    ) -> [SoftBodyMeshState]? {
        let orderedDescriptors = descriptors.sorted { $0.entity.rawValue < $1.entity.rawValue }
        let vertexCapacity = orderedDescriptors.reduce(0) { $0 + $1.cloth.vertexCount }
        var nativeStates = [GuavaJoltSoftBodyState](
            repeating: GuavaJoltSoftBodyState(),
            count: orderedDescriptors.count
        )
        var positions = [Float](repeating: 0, count: vertexCapacity * 3)
        var copiedVertexCount: UInt32 = 0
        let copiedStateCount = nativeStates.withUnsafeMutableBufferPointer { stateBuffer in
            positions.withUnsafeMutableBufferPointer { positionBuffer in
                guava_jolt_context_copy_soft_body_states(
                    nativeContext,
                    stateBuffer.baseAddress,
                    stateBuffer.count,
                    positionBuffer.baseAddress,
                    vertexCapacity,
                    &copiedVertexCount
                )
            }
        }
        guard guava_jolt_context_last_error(nativeContext) == 0,
              Int(copiedStateCount) == orderedDescriptors.count,
              Int(copiedVertexCount) <= vertexCapacity else {
            return nil
        }
        let clothByEntity = Dictionary(uniqueKeysWithValues: orderedDescriptors.map {
            ($0.entity.rawValue, $0.cloth)
        })
        let states: [SoftBodyMeshState] = nativeStates
            .prefix(Int(copiedStateCount))
            .compactMap { state -> SoftBodyMeshState? in
            guard let cloth = clothByEntity[state.entity_id] else { return nil }
            let offset = Int(state.vertex_offset)
            let count = Int(state.vertex_count)
            guard offset >= 0, count == cloth.vertexCount,
                  offset + count <= Int(copiedVertexCount) else { return nil }
            let deformedPositions = (offset..<(offset + count)).map { index in
                SIMD3<Float>(
                    positions[index * 3],
                    positions[index * 3 + 1],
                    positions[index * 3 + 2]
                )
            }
            return SoftBodyMeshState(
                entity: EntityID(rawValue: state.entity_id),
                positions: deformedPositions,
                triangleIndices: cloth.triangleIndices,
                isSleeping: state.is_sleeping != 0
            )
            }
        guard states.count == orderedDescriptors.count else { return nil }
        return states
    }

    private func synchronizeVehicles(
        upserts: [PhysicsVehicleDescriptor],
        removals: [UInt64],
        fullSnapshot: Bool,
        nativeContext: GuavaJoltContext
    ) -> (success: Bool, stats: GuavaJoltVehicleSyncStats) {
        let vehicleDescs = upserts.map(makeVehicleDesc)
        let wheelsByVehicle = upserts.map { $0.vehicle.wheels.map(makeVehicleWheelDesc) }
        let differentialsByVehicle = upserts.map {
            $0.vehicle.differentials.map(makeVehicleDifferentialDesc)
        }
        let antiRollBarsByVehicle = upserts.map {
            $0.vehicle.antiRollBars.map(makeVehicleAntiRollBarDesc)
        }
        let trackConfigurationsByVehicle: [[VehicleTrackConfiguration]] = upserts.map {
            guard case let .tracked(configuration) = $0.vehicle.controller else { return [] }
            return [configuration.leftTrack, configuration.rightTrack]
        }
        let tracksByVehicle = trackConfigurationsByVehicle.map { $0.map(makeVehicleTrackDesc) }
        let trackWheelIndicesByVehicle = trackConfigurationsByVehicle.map {
            $0.flatMap { track in track.wheels.map(Int32.init(clamping:)) }
        }
        let gearsByVehicle = upserts.map { $0.vehicle.transmission.gearRatios }
        let reverseGearsByVehicle = upserts.map { $0.vehicle.transmission.reverseGearRatios }
        let flatWheels = wheelsByVehicle.flatMap { $0 }
        let flatDifferentials = differentialsByVehicle.flatMap { $0 }
        let flatAntiRollBars = antiRollBarsByVehicle.flatMap { $0 }
        let flatTracks = tracksByVehicle.flatMap { $0 }
        let flatTrackWheelIndices = trackWheelIndicesByVehicle.flatMap { $0 }
        let flatGears = gearsByVehicle.flatMap { $0 }
        let flatReverseGears = reverseGearsByVehicle.flatMap { $0 }
        var stats = GuavaJoltVehicleSyncStats()
        let wheelStorage = allocateNativeBuffer(copying: flatWheels)
        let differentialStorage = allocateNativeBuffer(copying: flatDifferentials)
        let antiRollStorage = allocateNativeBuffer(copying: flatAntiRollBars)
        let trackWheelStorage = allocateNativeBuffer(copying: flatTrackWheelIndices)
        let trackStorage = allocateNativeBuffer(copying: flatTracks)
        let gearStorage = allocateNativeBuffer(copying: flatGears)
        let reverseGearStorage = allocateNativeBuffer(copying: flatReverseGears)
        let vehicleStorage = allocateNativeBuffer(copying: vehicleDescs)
        let removalStorage = allocateNativeBuffer(copying: removals)
        defer {
            deallocateNativeBuffer(wheelStorage, count: flatWheels.count)
            deallocateNativeBuffer(differentialStorage, count: flatDifferentials.count)
            deallocateNativeBuffer(antiRollStorage, count: flatAntiRollBars.count)
            deallocateNativeBuffer(trackWheelStorage, count: flatTrackWheelIndices.count)
            deallocateNativeBuffer(trackStorage, count: flatTracks.count)
            deallocateNativeBuffer(gearStorage, count: flatGears.count)
            deallocateNativeBuffer(reverseGearStorage, count: flatReverseGears.count)
            deallocateNativeBuffer(vehicleStorage, count: vehicleDescs.count)
            deallocateNativeBuffer(removalStorage, count: removals.count)
        }

        var trackWheelOffset = 0
        for index in flatTracks.indices {
            let count = Int(trackStorage[index].wheel_count)
            trackStorage[index].wheels = count > 0
                ? UnsafePointer(trackWheelStorage.advanced(by: trackWheelOffset)) : nil
            trackWheelOffset += count
        }

        var wheelOffset = 0
        var differentialOffset = 0
        var antiRollOffset = 0
        var trackOffset = 0
        var gearOffset = 0
        var reverseGearOffset = 0
        for index in vehicleDescs.indices {
            let wheelCount = wheelsByVehicle[index].count
            let differentialCount = differentialsByVehicle[index].count
            let antiRollCount = antiRollBarsByVehicle[index].count
            let trackCount = tracksByVehicle[index].count
            let gearCount = gearsByVehicle[index].count
            let reverseGearCount = reverseGearsByVehicle[index].count
            vehicleStorage[index].wheels = wheelCount > 0
                ? UnsafePointer(wheelStorage.advanced(by: wheelOffset)) : nil
            vehicleStorage[index].differentials = differentialCount > 0
                ? UnsafePointer(differentialStorage.advanced(by: differentialOffset)) : nil
            vehicleStorage[index].anti_roll_bars = antiRollCount > 0
                ? UnsafePointer(antiRollStorage.advanced(by: antiRollOffset)) : nil
            vehicleStorage[index].tracks = trackCount > 0
                ? UnsafePointer(trackStorage.advanced(by: trackOffset)) : nil
            vehicleStorage[index].gear_ratios = gearCount > 0
                ? UnsafePointer(gearStorage.advanced(by: gearOffset)) : nil
            vehicleStorage[index].reverse_gear_ratios = reverseGearCount > 0
                ? UnsafePointer(reverseGearStorage.advanced(by: reverseGearOffset)) : nil
            wheelOffset += wheelCount
            differentialOffset += differentialCount
            antiRollOffset += antiRollCount
            trackOffset += trackCount
            gearOffset += gearCount
            reverseGearOffset += reverseGearCount
        }
        let success = guava_jolt_context_sync_vehicles(
            nativeContext,
            vehicleDescs.isEmpty ? nil : vehicleStorage,
            vehicleDescs.count,
            removals.isEmpty ? nil : removalStorage,
            removals.count,
            fullSnapshot,
            &stats
        )
        return (success, stats)
    }

    private func makeVehicleDesc(_ descriptor: PhysicsVehicleDescriptor) -> GuavaJoltVehicleDesc {
        let vehicle = descriptor.vehicle
        let transmission = vehicle.transmission
        var result = GuavaJoltVehicleDesc()
        result.entity_id = descriptor.entity.rawValue
        result.is_enabled = vehicle.isEnabled ? 1 : 0
        result.transmission_mode = transmission.mode.rawValue
        result.controller_type = vehicle.controller.kind.rawValue
        result.up_x = vehicle.up.x
        result.up_y = vehicle.up.y
        result.up_z = vehicle.up.z
        result.forward_x = vehicle.forward.x
        result.forward_y = vehicle.forward.y
        result.forward_z = vehicle.forward.z
        result.max_pitch_roll_angle = vehicle.maxPitchRollAngle
        result.engine_max_torque = vehicle.engine.maxTorque
        result.engine_min_rpm = vehicle.engine.minRPM
        result.engine_max_rpm = vehicle.engine.maxRPM
        result.engine_inertia = vehicle.engine.inertia
        result.engine_angular_damping = vehicle.engine.angularDamping
        result.transmission_switch_time = transmission.switchTime
        result.transmission_clutch_release_time = transmission.clutchReleaseTime
        result.transmission_switch_latency = transmission.switchLatency
        result.transmission_shift_up_rpm = transmission.shiftUpRPM
        result.transmission_shift_down_rpm = transmission.shiftDownRPM
        result.transmission_clutch_strength = transmission.clutchStrength
        if case let .tracked(configuration) = vehicle.controller {
            result.tracked_longitudinal_friction = configuration.longitudinalFriction
            result.tracked_lateral_friction = configuration.lateralFriction
            result.track_count = 2
        }
        if case let .motorcycle(configuration) = vehicle.controller {
            result.motorcycle_max_lean_angle = configuration.maxLeanAngle
            result.motorcycle_lean_spring_constant = configuration.leanSpringConstant
            result.motorcycle_lean_spring_damping = configuration.leanSpringDamping
            result.motorcycle_lean_spring_integration_coefficient =
                configuration.leanSpringIntegrationCoefficient
            result.motorcycle_lean_spring_integration_coefficient_decay =
                configuration.leanSpringIntegrationCoefficientDecay
            result.motorcycle_lean_smoothing_factor = configuration.leanSmoothingFactor
            result.motorcycle_enable_lean_controller =
                configuration.isLeanControllerEnabled ? 1 : 0
            result.motorcycle_enable_lean_steering_limit =
                configuration.isLeanSteeringLimitEnabled ? 1 : 0
        }
        result.wheel_count = UInt32(vehicle.wheels.count)
        result.differential_count = UInt32(vehicle.differentials.count)
        result.anti_roll_bar_count = UInt32(vehicle.antiRollBars.count)
        result.gear_ratio_count = UInt32(transmission.gearRatios.count)
        result.reverse_gear_ratio_count = UInt32(transmission.reverseGearRatios.count)
        return result
    }

    private func makeVehicleTrackDesc(
        _ track: VehicleTrackConfiguration
    ) -> GuavaJoltVehicleTrackDesc {
        var result = GuavaJoltVehicleTrackDesc()
        result.driven_wheel = Int32(clamping: track.drivenWheel)
        result.wheel_count = UInt32(track.wheels.count)
        result.inertia = track.inertia
        result.angular_damping = track.angularDamping
        result.max_brake_torque = track.maxBrakeTorque
        result.differential_ratio = track.differentialRatio
        return result
    }

    private func makeVehicleWheelDesc(_ wheel: VehicleWheelConfiguration) -> GuavaJoltVehicleWheelDesc {
        var result = GuavaJoltVehicleWheelDesc()
        result.position_x = wheel.position.x
        result.position_y = wheel.position.y
        result.position_z = wheel.position.z
        result.suspension_direction_x = wheel.suspensionDirection.x
        result.suspension_direction_y = wheel.suspensionDirection.y
        result.suspension_direction_z = wheel.suspensionDirection.z
        result.steering_axis_x = wheel.steeringAxis.x
        result.steering_axis_y = wheel.steeringAxis.y
        result.steering_axis_z = wheel.steeringAxis.z
        result.wheel_up_x = wheel.wheelUp.x
        result.wheel_up_y = wheel.wheelUp.y
        result.wheel_up_z = wheel.wheelUp.z
        result.wheel_forward_x = wheel.wheelForward.x
        result.wheel_forward_y = wheel.wheelForward.y
        result.wheel_forward_z = wheel.wheelForward.z
        result.suspension_min_length = wheel.suspensionMinLength
        result.suspension_max_length = wheel.suspensionMaxLength
        result.suspension_preload_length = wheel.suspensionPreloadLength
        result.suspension_frequency = wheel.suspensionFrequency
        result.suspension_damping = wheel.suspensionDamping
        result.radius = wheel.radius
        result.width = wheel.width
        result.inertia = wheel.inertia
        result.angular_damping = wheel.angularDamping
        result.max_steer_angle = wheel.maxSteerAngle
        result.max_brake_torque = wheel.maxBrakeTorque
        result.max_hand_brake_torque = wheel.maxHandBrakeTorque
        return result
    }

    private func makeVehicleDifferentialDesc(
        _ differential: VehicleDifferentialConfiguration
    ) -> GuavaJoltVehicleDifferentialDesc {
        var result = GuavaJoltVehicleDifferentialDesc()
        result.left_wheel = Int32(clamping: differential.leftWheel)
        result.right_wheel = Int32(clamping: differential.rightWheel)
        result.differential_ratio = differential.differentialRatio
        result.left_right_split = differential.leftRightSplit
        result.limited_slip_ratio = differential.limitedSlipRatio
        result.engine_torque_ratio = differential.engineTorqueRatio
        return result
    }

    private func makeVehicleAntiRollBarDesc(
        _ bar: VehicleAntiRollBarConfiguration
    ) -> GuavaJoltVehicleAntiRollBarDesc {
        var result = GuavaJoltVehicleAntiRollBarDesc()
        result.left_wheel = Int32(clamping: bar.leftWheel)
        result.right_wheel = Int32(clamping: bar.rightWheel)
        result.stiffness = bar.stiffness
        return result
    }

    private func makeBodyDesc(from descriptor: PhysicsBodyDescriptor) -> GuavaJoltBodyDesc {
        var flags: UInt32 = 0
        if descriptor.rigidBody?.allowSleep ?? false {
            flags |= Self.rigidBodyAllowSleepFlag
        }
        if descriptor.rigidBody?.continuousCollisionDetection == true
            || descriptor.rigidBody?.motionQuality == .linearCast {
            flags |= Self.rigidBodyContinuousCollisionFlag
        }

        let rotation = rotationQuaternion(from: descriptor.worldTransform.matrix)

        var boxHalfExtents = SIMD3<Float>.zero
        var sphereRadius: Float = 0
        var capsuleRadius: Float = 0
        var capsuleHalfHeight: Float = 0
        var shapeCenter = SIMD3<Float>.zero
        var shapeScale = SIMD3<Float>(1, 1, 1)
        var layerID: UInt16 = 0
        var layerMask: UInt16 = .max

        if let collider = descriptor.collider {
            shapeScale = matrixScale(of: descriptor.worldTransform.matrix)
            layerID = collider.layerID
            layerMask = collider.layerMask
            if collider.isTrigger {
                flags |= Self.colliderIsTriggerFlag
            }

            if let firstShape = collider.shapes.first?.shape {
            switch firstShape {
            case let .box(halfExtents, center):
                flags |= Self.colliderHasBoxFlag
                boxHalfExtents = halfExtents
                shapeCenter = center
            case let .sphere(radius, center):
                flags |= Self.colliderHasSphereFlag
                sphereRadius = radius
                shapeCenter = center
            case let .capsule(radius, halfHeight, center):
                flags |= Self.colliderHasCapsuleFlag
                capsuleRadius = radius
                capsuleHalfHeight = halfHeight
                shapeCenter = center
            case let .cylinder(radius, halfHeight, center):
                flags |= Self.colliderHasCylinderFlag
                capsuleRadius = radius
                capsuleHalfHeight = halfHeight
                shapeCenter = center
            case let .heightField(_, center):
                flags |= Self.colliderHasMeshFlag
                shapeCenter = center
            case let .mesh(_, center):
                flags |= Self.colliderHasMeshFlag
                shapeCenter = center
            case let .convex(_, center):
                flags |= Self.colliderHasConvexFlag
                shapeCenter = center
            }
            }
        }

        return GuavaJoltBodyDesc(
            entity_id: descriptor.entity.rawValue,
            motion_type: motionTypeValue(descriptor.rigidBody?.motionType ?? .static),
            flags: flags,
            position_x: descriptor.worldTransform.translation.x,
            position_y: descriptor.worldTransform.translation.y,
            position_z: descriptor.worldTransform.translation.z,
            rotation_x: rotation.vector.x,
            rotation_y: rotation.vector.y,
            rotation_z: rotation.vector.z,
            rotation_w: rotation.vector.w,
            shape_center_x: shapeCenter.x,
            shape_center_y: shapeCenter.y,
            shape_center_z: shapeCenter.z,
            shape_scale_x: shapeScale.x,
            shape_scale_y: shapeScale.y,
            shape_scale_z: shapeScale.z,
            linear_velocity_x: descriptor.rigidBody?.linearVelocity.x ?? 0,
            linear_velocity_y: descriptor.rigidBody?.linearVelocity.y ?? 0,
            linear_velocity_z: descriptor.rigidBody?.linearVelocity.z ?? 0,
            angular_velocity_x: descriptor.rigidBody?.angularVelocity.x ?? 0,
            angular_velocity_y: descriptor.rigidBody?.angularVelocity.y ?? 0,
            angular_velocity_z: descriptor.rigidBody?.angularVelocity.z ?? 0,
            accumulated_force_x: descriptor.rigidBody?.accumulatedForce.x ?? 0,
            accumulated_force_y: descriptor.rigidBody?.accumulatedForce.y ?? 0,
            accumulated_force_z: descriptor.rigidBody?.accumulatedForce.z ?? 0,
            accumulated_torque_x: descriptor.rigidBody?.accumulatedTorque.x ?? 0,
            accumulated_torque_y: descriptor.rigidBody?.accumulatedTorque.y ?? 0,
            accumulated_torque_z: descriptor.rigidBody?.accumulatedTorque.z ?? 0,
            accumulated_linear_impulse_x: descriptor.rigidBody?.accumulatedLinearImpulse.x ?? 0,
            accumulated_linear_impulse_y: descriptor.rigidBody?.accumulatedLinearImpulse.y ?? 0,
            accumulated_linear_impulse_z: descriptor.rigidBody?.accumulatedLinearImpulse.z ?? 0,
            accumulated_angular_impulse_x: descriptor.rigidBody?.accumulatedAngularImpulse.x ?? 0,
            accumulated_angular_impulse_y: descriptor.rigidBody?.accumulatedAngularImpulse.y ?? 0,
            accumulated_angular_impulse_z: descriptor.rigidBody?.accumulatedAngularImpulse.z ?? 0,
            box_half_extent_x: boxHalfExtents.x,
            box_half_extent_y: boxHalfExtents.y,
            box_half_extent_z: boxHalfExtents.z,
            sphere_radius: sphereRadius,
            capsule_radius: capsuleRadius,
            capsule_half_height: capsuleHalfHeight,
            mass: descriptor.rigidBody?.mass ?? 0,
            gravity_scale: descriptor.rigidBody?.gravityScale ?? 0,
            linear_damping: descriptor.rigidBody?.linearDamping ?? 0,
            angular_damping: descriptor.rigidBody?.angularDamping ?? 0,
            is_sleeping: descriptor.rigidBody?.isSleeping == true ? 1 : 0,
            reserved0: 0,
            reserved1: 0,
            layer_id: layerID,
            layer_mask: layerMask,
            friction: descriptor.collider?.material.friction ?? PhysicsMaterial().friction,
            restitution: descriptor.collider?.material.restitution ?? PhysicsMaterial().restitution,
            density: descriptor.collider?.material.density ?? PhysicsMaterial().density,
            shape_instances: nil,
            shape_instance_count: 0,
            shape_instances_reserved: 0,
            mass_mode: descriptor.rigidBody?.massMode == .density ? 1 : 0,
            motion_quality: descriptor.rigidBody?.motionQuality == .linearCast ? 1 : 0,
            allowed_dofs: UInt8(0x3F) & ~(descriptor.rigidBody?.axisLocks.rawValue ?? 0),
            has_center_of_mass_override: descriptor.rigidBody?.centerOfMassOverride == nil ? 0 : 1,
            has_inertia_override: descriptor.rigidBody?.inertiaDiagonalOverride == nil ? 0 : 1,
            has_kinematic_target: descriptor.rigidBody?.kinematicTarget == nil ? 0 : 1,
            rigid_body_reserved: 0,
            max_linear_velocity: descriptor.rigidBody?.maxLinearVelocity ?? 500,
            max_angular_velocity: descriptor.rigidBody?.maxAngularVelocity ?? (0.25 * .pi * 60),
            center_of_mass_x: descriptor.rigidBody?.centerOfMassOverride?.x ?? 0,
            center_of_mass_y: descriptor.rigidBody?.centerOfMassOverride?.y ?? 0,
            center_of_mass_z: descriptor.rigidBody?.centerOfMassOverride?.z ?? 0,
            inertia_x: descriptor.rigidBody?.inertiaDiagonalOverride?.x ?? 0,
            inertia_y: descriptor.rigidBody?.inertiaDiagonalOverride?.y ?? 0,
            inertia_z: descriptor.rigidBody?.inertiaDiagonalOverride?.z ?? 0,
            target_position_x: descriptor.rigidBody?.kinematicTarget?.position.x ?? 0,
            target_position_y: descriptor.rigidBody?.kinematicTarget?.position.y ?? 0,
            target_position_z: descriptor.rigidBody?.kinematicTarget?.position.z ?? 0,
            target_rotation_x: descriptor.rigidBody?.kinematicTarget?.rotation.x ?? 0,
            target_rotation_y: descriptor.rigidBody?.kinematicTarget?.rotation.y ?? 0,
            target_rotation_z: descriptor.rigidBody?.kinematicTarget?.rotation.z ?? 0,
            target_rotation_w: descriptor.rigidBody?.kinematicTarget?.rotation.w ?? 1
        )
    }

    private func makeShapeInstances(from descriptor: PhysicsBodyDescriptor) -> [GuavaJoltShapeInstance] {
        guard let collider = descriptor.collider else { return [] }
        let worldScale = matrixScale(of: descriptor.worldTransform.matrix)
        return collider.shapes.map { instance in
            let center = instance.shape.center
            let position = (instance.localPosition + center) * worldScale
            let scale = instance.localScale * worldScale
            var shapeType: UInt8 = 0
            var halfExtents = SIMD3<Float>.zero
            var radius: Float = 0
            var halfHeight: Float = 0
            switch instance.shape {
            case let .box(value, _):
                shapeType = 0
                halfExtents = value
            case let .sphere(value, _):
                shapeType = 1
                radius = value
            case let .capsule(r, h, _):
                shapeType = 2
                radius = r
                halfHeight = h
            case let .cylinder(r, h, _):
                shapeType = 3
                radius = r
                halfHeight = h
            case .mesh:
                shapeType = 4
            case .convex:
                shapeType = 5
            case .heightField:
                shapeType = 6
            }
            return GuavaJoltShapeInstance(
                shape_type: shapeType,
                reserved0: 0,
                reserved1: 0,
                position_x: position.x,
                position_y: position.y,
                position_z: position.z,
                rotation_x: instance.localRotation.x,
                rotation_y: instance.localRotation.y,
                rotation_z: instance.localRotation.z,
                rotation_w: instance.localRotation.w,
                scale_x: scale.x,
                scale_y: scale.y,
                scale_z: scale.z,
                half_extent_x: halfExtents.x,
                half_extent_y: halfExtents.y,
                half_extent_z: halfExtents.z,
                radius: radius,
                half_height: halfHeight
            )
        }
    }

    private func makeCharacterDesc(from descriptor: PhysicsCharacterDescriptor) -> GuavaJoltCharacterDesc {
        let controller = descriptor.controller
        let rotation = rotationQuaternion(from: descriptor.worldTransform.matrix)
        return GuavaJoltCharacterDesc(
            entity_id: descriptor.entity.rawValue,
            position_x: descriptor.worldTransform.translation.x,
            position_y: descriptor.worldTransform.translation.y,
            position_z: descriptor.worldTransform.translation.z,
            rotation_x: rotation.vector.x,
            rotation_y: rotation.vector.y,
            rotation_z: rotation.vector.z,
            rotation_w: rotation.vector.w,
            center_x: controller.center.x,
            center_y: controller.center.y,
            center_z: controller.center.z,
            radius: controller.radius,
            standing_half_height: controller.standingHalfHeight,
            crouching_half_height: controller.crouchingHalfHeight,
            max_slope_radians: controller.maxSlopeDegrees * .pi / 180,
            step_height: controller.stepHeight,
            skin_width: controller.skinWidth,
            mass: controller.mass,
            max_strength: controller.maxStrength,
            gravity_scale: controller.gravityScale,
            layer_id: controller.layerID,
            layer_mask: controller.layerMask
        )
    }

    private func makeCharacterCommand(
        entity: EntityID,
        command: CharacterCommand
    ) -> GuavaJoltCharacterCommand {
        GuavaJoltCharacterCommand(
            entity_id: entity.rawValue,
            desired_velocity_x: command.desiredVelocity.x,
            desired_velocity_y: command.desiredVelocity.y,
            desired_velocity_z: command.desiredVelocity.z,
            jump_speed: command.jumpSpeed,
            jump_requested: command.jumpRequested ? 1 : 0,
            stance: command.stance.rawValue,
            reserved: 0
        )
    }

    private func makeCharacterState(_ state: GuavaJoltCharacterState) -> CharacterState {
        CharacterState(
            entity: EntityID(rawValue: state.entity_id),
            position: SIMD3<Float>(state.position_x, state.position_y, state.position_z),
            rotation: SIMD4<Float>(
                state.rotation_x, state.rotation_y, state.rotation_z, state.rotation_w
            ),
            linearVelocity: SIMD3<Float>(
                state.linear_velocity_x, state.linear_velocity_y, state.linear_velocity_z
            ),
            groundState: characterGroundState(state.ground_state),
            groundNormal: SIMD3<Float>(
                state.ground_normal_x, state.ground_normal_y, state.ground_normal_z
            ),
            groundVelocity: SIMD3<Float>(
                state.ground_velocity_x, state.ground_velocity_y, state.ground_velocity_z
            ),
            groundEntity: state.has_ground_entity == 0
                ? nil
                : EntityID(rawValue: state.ground_entity),
            stance: state.stance == 1 ? .crouching : .standing
        )
    }

    private func makeVehicleCommand(
        entity: EntityID,
        command: VehicleCommand
    ) -> GuavaJoltVehicleCommand {
        var result = GuavaJoltVehicleCommand()
        result.entity_id = entity.rawValue
        result.throttle = command.throttle
        result.steering = command.steering
        result.brake = command.brake
        result.hand_brake = command.handBrake
        result.manual_gear = Int32(clamping: command.manualGear ?? 0)
        result.clutch = command.clutch
        result.has_manual_gear = command.manualGear == nil ? 0 : 1
        return result
    }

    private func makeVehicleState(
        _ state: GuavaJoltVehicleState,
        wheelStates: [GuavaJoltVehicleWheelState]
    ) -> VehicleState {
        let lower = min(Int(state.wheel_state_offset), wheelStates.count)
        let upper = min(lower + Int(state.wheel_state_count), wheelStates.count)
        return VehicleState(
            entity: EntityID(rawValue: state.entity_id),
            forwardSpeed: state.forward_speed,
            engineRPM: state.engine_rpm,
            currentGear: Int(state.current_gear),
            clutchFriction: state.clutch_friction,
            wheels: wheelStates[lower..<upper].map { wheel in
                VehicleWheelState(
                    index: Int(wheel.wheel_index),
                    worldPosition: SIMD3<Float>(
                        wheel.world_position_x, wheel.world_position_y, wheel.world_position_z
                    ),
                    worldRotation: SIMD4<Float>(
                        wheel.world_rotation_x, wheel.world_rotation_y,
                        wheel.world_rotation_z, wheel.world_rotation_w
                    ),
                    angularVelocity: wheel.angular_velocity,
                    rotationAngle: wheel.rotation_angle,
                    steerAngle: wheel.steer_angle,
                    suspensionLength: wheel.suspension_length,
                    hasContact: wheel.has_contact != 0,
                    contactEntity: wheel.has_contact_entity == 0
                        ? nil : EntityID(rawValue: wheel.contact_entity_id),
                    contactPosition: SIMD3<Float>(
                        wheel.contact_position_x, wheel.contact_position_y, wheel.contact_position_z
                    ),
                    contactNormal: SIMD3<Float>(
                        wheel.contact_normal_x, wheel.contact_normal_y, wheel.contact_normal_z
                    )
                )
            }
        )
    }

    private func characterGroundState(_ raw: UInt8) -> CharacterGroundState {
        switch raw {
        case 0: return .onGround
        case 1: return .onSteepGround
        case 2: return .notSupported
        default: return .inAir
        }
    }

    private func makeConstraintDesc(from descriptor: PhysicsConstraintDescriptor) -> GuavaJoltConstraintDesc {
        let constraint = descriptor.constraint
        var result = GuavaJoltConstraintDesc()
        result.entity_id = descriptor.entity.rawValue
        result.entity_a = constraint.entityA.rawValue
        result.entity_b = constraint.entityB.rawValue
        result.constraint_type = constraintTypeValue(constraint.constraintType)
        result.is_enabled = constraint.isEnabled ? 1 : 0
        result.pivot_a_x = constraint.pivotA.x
        result.pivot_a_y = constraint.pivotA.y
        result.pivot_a_z = constraint.pivotA.z
        result.pivot_b_x = constraint.pivotB.x
        result.pivot_b_y = constraint.pivotB.y
        result.pivot_b_z = constraint.pivotB.z
        result.axis_a_x = constraint.axisA.x
        result.axis_a_y = constraint.axisA.y
        result.axis_a_z = constraint.axisA.z
        result.axis_b_x = constraint.axisB.x
        result.axis_b_y = constraint.axisB.y
        result.axis_b_z = constraint.axisB.z
        result.min_limit = constraint.minLimit
        result.max_limit = constraint.maxLimit
        result.break_force = constraint.breakForce
        result.break_torque = constraint.breakTorque

        func apply(_ spring: PhysicsJointSpring) {
            result.spring_frequency = spring.frequency
            result.spring_damping = spring.damping
        }
        func apply(_ motor: PhysicsJointMotor, angular: Bool = false) {
            if angular {
                result.angular_motor_mode = motorModeValue(motor.mode)
                result.angular_motor_target_position = motor.targetPosition
                result.angular_motor_target_velocity = motor.targetVelocity
                result.angular_motor_max_force = motor.maxForce
            } else {
                result.motor_mode = motorModeValue(motor.mode)
                result.motor_target_position = motor.targetPosition
                result.motor_target_velocity = motor.targetVelocity
                result.motor_max_force = motor.maxForce
            }
        }
        switch constraint.configuration {
        case .point, .fixed:
            break
        case let .distance(value):
            apply(value.spring)
        case let .hinge(value):
            apply(value.spring); apply(value.motor, angular: true)
        case let .slider(value):
            apply(value.spring); apply(value.motor)
        case let .cone(value):
            apply(value.spring)
            result.half_cone_angle = value.halfConeAngle
        case let .sixDOF(value):
            apply(value.spring); apply(value.linearMotor); apply(value.angularMotor, angular: true)
            result.linear_min_x = value.linearMinimum.x
            result.linear_min_y = value.linearMinimum.y
            result.linear_min_z = value.linearMinimum.z
            result.linear_max_x = value.linearMaximum.x
            result.linear_max_y = value.linearMaximum.y
            result.linear_max_z = value.linearMaximum.z
            result.angular_min_x = value.angularMinimum.x
            result.angular_min_y = value.angularMinimum.y
            result.angular_min_z = value.angularMinimum.z
            result.angular_max_x = value.angularMaximum.x
            result.angular_max_y = value.angularMaximum.y
            result.angular_max_z = value.angularMaximum.z
        }
        return result
    }

    private func makeBodyState(from descriptor: PhysicsBodyDescriptor) -> GuavaJoltBodyState {
        let rotation = rotationQuaternion(from: descriptor.worldTransform.matrix)
        return GuavaJoltBodyState(
            entity_id: descriptor.entity.rawValue,
            position_x: descriptor.worldTransform.translation.x,
            position_y: descriptor.worldTransform.translation.y,
            position_z: descriptor.worldTransform.translation.z,
            rotation_x: rotation.vector.x,
            rotation_y: rotation.vector.y,
            rotation_z: rotation.vector.z,
            rotation_w: rotation.vector.w,
            linear_velocity_x: descriptor.rigidBody?.linearVelocity.x ?? 0,
            linear_velocity_y: descriptor.rigidBody?.linearVelocity.y ?? 0,
            linear_velocity_z: descriptor.rigidBody?.linearVelocity.z ?? 0,
            angular_velocity_x: descriptor.rigidBody?.angularVelocity.x ?? 0,
            angular_velocity_y: descriptor.rigidBody?.angularVelocity.y ?? 0,
            angular_velocity_z: descriptor.rigidBody?.angularVelocity.z ?? 0,
            is_sleeping: descriptor.rigidBody?.isSleeping == true ? 1 : 0,
            reserved0: 0,
            reserved1: 0
        )
    }

    private func makeQueryFilter(_ filter: PhysicsQueryFilter) -> GuavaJoltQueryFilter {
        let excluded = filter.excludedEntities
        let nativeExcludedEntity = excluded.count == 1 ? excluded.first : nil
        return GuavaJoltQueryFilter(
            exclude_entity: nativeExcludedEntity?.rawValue ?? 0,
            has_exclude_entity: nativeExcludedEntity == nil ? 0 : 1,
            include_triggers: filter.includeTriggers ? 1 : 0,
            has_layer_id: filter.layerID == nil ? 0 : 1,
            reserved0: 0,
            layer_id: filter.layerID ?? 0,
            layer_mask: filter.layerMask
        )
    }

    private func makeOverlapShapeQuery(
        _ query: PhysicsOverlapShapeQuery,
        maxResults: UInt32
    ) -> GuavaJoltOverlapShapeQuery {
        let shape = queryShapeFields(query.shape)
        return GuavaJoltOverlapShapeQuery(
            shape_type: shape.type,
            reserved0: 0,
            reserved1: 0,
            position_x: query.position.x,
            position_y: query.position.y,
            position_z: query.position.z,
            rotation_x: query.rotation.x,
            rotation_y: query.rotation.y,
            rotation_z: query.rotation.z,
            rotation_w: query.rotation.w,
            box_half_extent_x: shape.boxHalfExtents.x,
            box_half_extent_y: shape.boxHalfExtents.y,
            box_half_extent_z: shape.boxHalfExtents.z,
            sphere_radius: shape.sphereRadius,
            capsule_radius: shape.capsuleRadius,
            capsule_half_height: shape.capsuleHalfHeight,
            max_results: maxResults
        )
    }

    private func makeSweepShapeQuery(_ query: PhysicsSweepShapeQuery) -> GuavaJoltSweepShapeQuery {
        let shape = queryShapeFields(query.shape)
        return GuavaJoltSweepShapeQuery(
            shape_type: shape.type,
            reserved0: 0,
            reserved1: 0,
            position_x: query.position.x,
            position_y: query.position.y,
            position_z: query.position.z,
            rotation_x: query.rotation.x,
            rotation_y: query.rotation.y,
            rotation_z: query.rotation.z,
            rotation_w: query.rotation.w,
            box_half_extent_x: shape.boxHalfExtents.x,
            box_half_extent_y: shape.boxHalfExtents.y,
            box_half_extent_z: shape.boxHalfExtents.z,
            sphere_radius: shape.sphereRadius,
            capsule_radius: shape.capsuleRadius,
            capsule_half_height: shape.capsuleHalfHeight,
            translation_x: query.translation.x,
            translation_y: query.translation.y,
            translation_z: query.translation.z
        )
    }

    private func queryShapeFields(_ shape: PhysicsQueryShape) -> (
        type: UInt8,
        boxHalfExtents: SIMD3<Float>,
        sphereRadius: Float,
        capsuleRadius: Float,
        capsuleHalfHeight: Float
    ) {
        switch shape {
        case let .box(halfExtents):
            return (
                Self.queryShapeBox,
                SIMD3<Float>(max(halfExtents.x, 0), max(halfExtents.y, 0), max(halfExtents.z, 0)),
                0,
                0,
                0
            )
        case let .sphere(radius):
            return (Self.queryShapeSphere, .zero, max(radius, 0), 0, 0)
        case let .capsule(radius, halfHeight):
            return (Self.queryShapeCapsule, .zero, 0, max(radius, 0), max(halfHeight, 0))
        }
    }

    private func makeRaycastHit(_ hit: GuavaJoltRaycastHit) -> PhysicsRaycastHit {
        PhysicsRaycastHit(
            entity: EntityID(rawValue: hit.entity_id),
            subShapeID: hit.sub_shape_id,
            distance: hit.distance,
            position: SIMD3<Float>(hit.position_x, hit.position_y, hit.position_z),
            normal: SIMD3<Float>(hit.normal_x, hit.normal_y, hit.normal_z),
            bounds: SpatialAABB(
                min: SIMD3<Float>(hit.bounds_min_x, hit.bounds_min_y, hit.bounds_min_z),
                max: SIMD3<Float>(hit.bounds_max_x, hit.bounds_max_y, hit.bounds_max_z)
            ),
            isTrigger: hit.is_trigger != 0
        )
    }

    private func makeOverlapHit(_ hit: GuavaJoltOverlapHit) -> PhysicsOverlapHit {
        PhysicsOverlapHit(
            entity: EntityID(rawValue: hit.entity_id),
            subShapeID: hit.sub_shape_id,
            bounds: SpatialAABB(
                min: SIMD3<Float>(hit.bounds_min_x, hit.bounds_min_y, hit.bounds_min_z),
                max: SIMD3<Float>(hit.bounds_max_x, hit.bounds_max_y, hit.bounds_max_z)
            ),
            isTrigger: hit.is_trigger != 0
        )
    }

    private func makeSweepHit(_ hit: GuavaJoltSweepHit) -> PhysicsSweepHit {
        PhysicsSweepHit(
            entity: EntityID(rawValue: hit.entity_id),
            subShapeID: hit.sub_shape_id,
            fraction: hit.fraction,
            distance: hit.distance,
            position: SIMD3<Float>(hit.position_x, hit.position_y, hit.position_z),
            normal: SIMD3<Float>(hit.normal_x, hit.normal_y, hit.normal_z),
            bounds: SpatialAABB(
                min: SIMD3<Float>(hit.bounds_min_x, hit.bounds_min_y, hit.bounds_min_z),
                max: SIMD3<Float>(hit.bounds_max_x, hit.bounds_max_y, hit.bounds_max_z)
            ),
            isTrigger: hit.is_trigger != 0
        )
    }

    private func copyContactEvents(
        from nativeContext: GuavaJoltContext,
        expectedCount: Int
    ) -> [PhysicsContactEvent] {
        guard expectedCount > 0 else { return [] }
        var events = [GuavaJoltContactEvent](
            repeating: GuavaJoltContactEvent(),
            count: expectedCount
        )
        let count = events.withUnsafeMutableBufferPointer { buffer in
            guava_jolt_context_copy_contact_events(
                nativeContext,
                buffer.baseAddress,
                buffer.count
            )
        }
        return events
            .prefix(min(Int(count), events.count))
            .map(makeContactEvent)
    }

    private func makeContactEvent(_ event: GuavaJoltContactEvent) -> PhysicsContactEvent {
        PhysicsContactEvent(
            entityA: EntityID(rawValue: event.entity_a),
            entityB: EntityID(rawValue: event.entity_b),
            subShapeIDA: event.sub_shape_id_a,
            subShapeIDB: event.sub_shape_id_b,
            kind: contactEventKind(event.kind),
            position: SIMD3<Float>(event.position_x, event.position_y, event.position_z),
            normal: SIMD3<Float>(event.normal_x, event.normal_y, event.normal_z),
            penetrationDepth: event.penetration_depth,
            relativeVelocity: SIMD3<Float>(
                event.relative_velocity_x,
                event.relative_velocity_y,
                event.relative_velocity_z
            ),
            impulse: event.impulse
        )
    }

    private func motionTypeValue(_ motionType: RigidBodyMotionType) -> UInt32 {
        switch motionType {
        case .static:
            return 0
        case .dynamic:
            return 1
        case .kinematic:
            return 2
        }
    }

    private func constraintTypeValue(_ type: PhysicsJointKind) -> UInt8 {
        switch type {
        case .pointToPoint:
            return 0
        case .hinge:
            return 1
        case .fixed:
            return 4
        case .slider:
            return 2
        case .distance:
            return 3
        case .cone:
            return 5
        case .sixDOF:
            return 6
        }
    }

    private func motorModeValue(_ mode: PhysicsJointMotorMode) -> UInt8 {
        switch mode {
        case .disabled: return 0
        case .velocity: return 1
        case .position: return 2
        }
    }

    private func contactEventKind(_ raw: UInt8) -> PhysicsContactEventKind {
        switch raw {
        case 0:
            return .began
        case 1:
            return .stayed
        default:
            return .ended
        }
    }

    private func makeWriteback(from state: GuavaJoltBodyState,
                               descriptorsByEntity: [UInt64: PhysicsBodyDescriptor]) -> PhysicsBodyWriteback? {
        guard let descriptor = descriptorsByEntity[state.entity_id],
              let rigidBody = descriptor.rigidBody,
              rigidBody.motionType != .static else {
            return nil
        }

        let rotation = normalizedQuaternion(
            SIMD4<Float>(state.rotation_x, state.rotation_y, state.rotation_z, state.rotation_w)
        )
        let matrix = transformMatrix(
            translation: SIMD3<Float>(state.position_x, state.position_y, state.position_z),
            rotation: rotation,
            scale: matrixScale(of: descriptor.worldTransform.matrix)
        )
        return PhysicsBodyWriteback(
            entity: descriptor.entity,
            worldTransform: WorldTransform(matrix: matrix),
            linearVelocity: SIMD3<Float>(
                state.linear_velocity_x,
                state.linear_velocity_y,
                state.linear_velocity_z
            ),
            angularVelocity: SIMD3<Float>(
                state.angular_velocity_x,
                state.angular_velocity_y,
                state.angular_velocity_z
            ),
            isSleeping: state.is_sleeping != 0
        )
    }

    private func rotationQuaternion(from matrix: simd_float4x4) -> simd_quatf {
        let x = normalizedBasis(SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                                fallback: SIMD3<Float>(1, 0, 0))
        let y = normalizedBasis(SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                                fallback: SIMD3<Float>(0, 1, 0))
        let z = normalizedBasis(SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z),
                                fallback: SIMD3<Float>(0, 0, 1))
        let rotationMatrix = simd_float3x3(columns: (x, y, z))
        return simd_quatf(rotationMatrix)
    }

    private func matrixScale(of matrix: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(
            simd_length(SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z)),
            simd_length(SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z)),
            simd_length(SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z))
        )
    }

    private func transformMatrix(translation: SIMD3<Float>,
                                 rotation: simd_quatf,
                                 scale: SIMD3<Float>) -> simd_float4x4 {
        let basisX = rotation.act(SIMD3<Float>(1, 0, 0)) * scale.x
        let basisY = rotation.act(SIMD3<Float>(0, 1, 0)) * scale.y
        let basisZ = rotation.act(SIMD3<Float>(0, 0, 1)) * scale.z
        return simd_float4x4(columns: (
            SIMD4<Float>(basisX, 0),
            SIMD4<Float>(basisY, 0),
            SIMD4<Float>(basisZ, 0),
            SIMD4<Float>(translation, 1)
        ))
    }

    private func normalizedQuaternion(_ vector: SIMD4<Float>) -> simd_quatf {
        let length = simd_length(vector)
        guard length > 0.000_001 else {
            return simd_quatf(vector: SIMD4<Float>(0, 0, 0, 1))
        }
        return simd_quatf(vector: vector / length)
    }

    private func normalizedBasis(_ basis: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let length = simd_length(basis)
        guard length > 0.000_001 else { return fallback }
        return basis / length
    }
}

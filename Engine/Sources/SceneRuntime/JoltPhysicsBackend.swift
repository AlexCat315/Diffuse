import CJoltBridge
import SIMDCompat

public final class JoltPhysicsBackend: PhysicsBackend, @unchecked Sendable {
    private static let expectedABIVersion: UInt32 = 2
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

    public init() {
        var layout = GuavaJoltABILayout()
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
        if compatible {
            context = guava_jolt_context_create()
        } else {
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
        guard let nativeContext = self.context else {
            lastPreparedBodyCount = context.activeBodies.count
            return PhysicsPrepareResult(
                synchronizedBodies: context.activeBodies.count,
                synchronizedConstraints: context.activeConstraints.count,
                error: initializationError
            )
        }

        var bodyDescs = context.activeBodies.map(makeBodyDesc)
        let constraintDescs = context.activeConstraints.map(makeConstraintDesc)
        let shapeInstancesByBody = context.activeBodies.map(makeShapeInstances)
        let flatShapeInstances = shapeInstancesByBody.flatMap { $0 }
        lastPreparedBodyCount = context.activeBodies.count

        // Collect mesh geometry into flat arrays so C pointers stay valid.
        var flatVertices: [Float] = []
        var flatIndices: [UInt32] = []
        var meshDescs: [GuavaJoltMeshGeometry] = []
        meshDescs.reserveCapacity(context.activeBodies.count)
        let activeEntities = Set(context.activeBodies.map(\.entity))
        meshRevisionByEntity = meshRevisionByEntity.filter { activeEntities.contains($0.key) }
        for descriptor in context.activeBodies {
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

        return PhysicsPrepareResult(
            synchronizedBodies: Int(stats.synchronized_bodies),
            synchronizedConstraints: Int(stats.synchronized_constraints),
            removedBodies: Int(stats.removed_bodies),
            removedConstraints: Int(stats.removed_constraints)
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
                .map(makeCharacterState)
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

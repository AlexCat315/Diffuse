import CJoltBridge
import SIMDCompat

public final class JoltPhysicsBackend: PhysicsBackend, @unchecked Sendable {
    private static let colliderHasBoxFlag: UInt32 = 1 << 0
    private static let colliderHasSphereFlag: UInt32 = 1 << 1
    private static let colliderHasMeshFlag: UInt32 = 1 << 2
    private static let colliderIsTriggerFlag: UInt32 = 1 << 3
    private static let rigidBodyAllowSleepFlag: UInt32 = 1 << 4
    private static let colliderHasCapsuleFlag: UInt32 = 1 << 5
    private static let colliderHasConvexFlag: UInt32 = 1 << 6
    private static let rigidBodyContinuousCollisionFlag: UInt32 = 1 << 7

    private var context: GuavaJoltContext?
    private var lastPreparedBodyCount: Int = 0

    public init() {
        context = guava_jolt_context_create()
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
                synchronizedConstraints: context.activeConstraints.count
            )
        }

        let bodyDescs = context.activeBodies.map(makeBodyDesc)
        let constraintDescs = context.activeConstraints.map(makeConstraintDesc)
        lastPreparedBodyCount = context.activeBodies.count

        // Collect mesh geometry into flat arrays so C pointers stay valid.
        var flatVertices: [Float] = []
        var flatIndices: [UInt32] = []
        var meshDescs: [GuavaJoltMeshGeometry] = []
        meshDescs.reserveCapacity(context.activeBodies.count)
        for descriptor in context.activeBodies {
            guard let geometry = descriptor.meshGeometry,
                  geometry.triangleCount > 0,
                  !geometry.positions.isEmpty else {
                continue
            }
            var desc = GuavaJoltMeshGeometry()
            desc.entity_id = descriptor.entity.rawValue
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

        // Patch pointers after all data is collected.
        var vertexCursor: UInt32 = 0
        var indexCursor: UInt32 = 0
        for i in 0..<meshDescs.count {
            let vc = meshDescs[i].vertex_count
            let ic = meshDescs[i].index_count
            meshDescs[i].vertices = flatVertices.withUnsafeBufferPointer { $0.baseAddress }.map { $0.advanced(by: Int(vertexCursor * 3)) } ?? nil
            meshDescs[i].indices = flatIndices.withUnsafeBufferPointer { $0.baseAddress }.map { $0.advanced(by: Int(indexCursor)) } ?? nil
            vertexCursor += vc
            indexCursor += ic
        }

        var stats = GuavaJoltPrepareStats()
        let success = bodyDescs.withUnsafeBufferPointer { bodyBuffer in
            constraintDescs.withUnsafeBufferPointer { constraintBuffer in
                flatVertices.withUnsafeBufferPointer { _ in
                    flatIndices.withUnsafeBufferPointer { _ in
                        meshDescs.withUnsafeBufferPointer { meshBuffer in
                            guava_jolt_context_prepare_with_meshes(
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

        guard success else {
            return PhysicsPrepareResult(
                synchronizedBodies: context.activeBodies.count,
                synchronizedConstraints: context.activeConstraints.count
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
                writebacks: []
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
                writebacks: []
            )
        }

        let contactEvents = copyContactEvents(
            from: nativeContext,
            expectedCount: Int(stats.contact_count)
        )
        return PhysicsStepResult(
            bodyCount: Int(stats.body_count),
            constraintCount: Int(stats.constraint_count),
            contactCount: max(Int(stats.contact_count), contactEvents.count),
            writebacks: bodyStates
                .prefix(Int(stats.state_count))
                .compactMap { makeWriteback(from: $0, descriptorsByEntity: descriptorsByEntity) },
            contactEvents: contactEvents
        )
    }

    public func raycast(_ query: PhysicsRaycastQuery, filter: PhysicsQueryFilter) -> PhysicsRaycastHit? {
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

    public func overlapAABB(_ query: PhysicsOverlapAABBQuery, filter: PhysicsQueryFilter) -> [PhysicsOverlapHit] {
        guard let nativeContext = context else { return [] }
        let maxResults = query.maxResults == .max
            ? UInt32.max
            : UInt32(max(0, min(query.maxResults, Int(UInt32.max))))
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
        return hits.prefix(min(Int(count), hits.count)).map(makeOverlapHit)
    }

    public func sweepAABB(_ query: PhysicsSweepAABBQuery, filter: PhysicsQueryFilter) -> PhysicsSweepHit? {
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
    }

    private func makeBodyDesc(from descriptor: PhysicsBodyDescriptor) -> GuavaJoltBodyDesc {
        var flags: UInt32 = 0
        if descriptor.rigidBody?.allowSleep ?? false {
            flags |= Self.rigidBodyAllowSleepFlag
        }
        if descriptor.rigidBody?.continuousCollisionDetection ?? false {
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

            switch collider.shape {
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
            case let .mesh(_, center):
                flags |= Self.colliderHasMeshFlag
                shapeCenter = center
            case let .convex(_, center):
                flags |= Self.colliderHasConvexFlag
                shapeCenter = center
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
            density: descriptor.collider?.material.density ?? PhysicsMaterial().density
        )
    }

    private func makeConstraintDesc(from descriptor: PhysicsConstraintDescriptor) -> GuavaJoltConstraintDesc {
        let constraint = descriptor.constraint
        return GuavaJoltConstraintDesc(
            entity_id: descriptor.entity.rawValue,
            entity_a: constraint.entityA.rawValue,
            entity_b: constraint.entityB.rawValue,
            constraint_type: constraintTypeValue(constraint.constraintType),
            is_enabled: constraint.isEnabled ? 1 : 0,
            reserved: 0,
            pivot_a_x: constraint.pivotA.x,
            pivot_a_y: constraint.pivotA.y,
            pivot_a_z: constraint.pivotA.z,
            pivot_b_x: constraint.pivotB.x,
            pivot_b_y: constraint.pivotB.y,
            pivot_b_z: constraint.pivotB.z,
            axis_a_x: constraint.axisA.x,
            axis_a_y: constraint.axisA.y,
            axis_a_z: constraint.axisA.z,
            axis_b_x: constraint.axisB.x,
            axis_b_y: constraint.axisB.y,
            axis_b_z: constraint.axisB.z,
            min_limit: constraint.minLimit,
            max_limit: constraint.maxLimit
        )
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
        GuavaJoltQueryFilter(
            exclude_entity: filter.excludeEntity?.rawValue ?? 0,
            has_exclude_entity: filter.excludeEntity == nil ? 0 : 1,
            include_triggers: filter.includeTriggers ? 1 : 0,
            has_layer_id: filter.layerID == nil ? 0 : 1,
            reserved0: 0,
            layer_id: filter.layerID ?? 0,
            layer_mask: filter.layerMask
        )
    }

    private func makeRaycastHit(_ hit: GuavaJoltRaycastHit) -> PhysicsRaycastHit {
        PhysicsRaycastHit(
            entity: EntityID(rawValue: hit.entity_id),
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
            kind: contactEventKind(event.kind),
            position: SIMD3<Float>(event.position_x, event.position_y, event.position_z),
            normal: SIMD3<Float>(event.normal_x, event.normal_y, event.normal_z),
            penetrationDepth: event.penetration_depth
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

    private func constraintTypeValue(_ type: ConstraintType) -> UInt8 {
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

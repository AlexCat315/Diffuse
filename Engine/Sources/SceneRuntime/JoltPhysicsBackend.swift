import CJoltBridge
import simd

public final class JoltPhysicsBackend: PhysicsBackend, @unchecked Sendable {
    private static let colliderHasBoxFlag: UInt32 = 1 << 0
    private static let colliderHasSphereFlag: UInt32 = 1 << 1
    private static let colliderHasMeshFlag: UInt32 = 1 << 2
    private static let colliderIsTriggerFlag: UInt32 = 1 << 3
    private static let rigidBodyAllowSleepFlag: UInt32 = 1 << 4
    private static let colliderHasCapsuleFlag: UInt32 = 1 << 5

    private var context: GuavaJoltContext?

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
            return PhysicsPrepareResult(
                synchronizedBodies: context.activeBodies.count,
                synchronizedConstraints: context.activeConstraints.count
            )
        }

        let bodyDescs = context.activeBodies.map(makeBodyDesc)
        let constraintDescs = context.activeConstraints.map(makeConstraintDesc)
        var stats = GuavaJoltPrepareStats()
        let success = bodyDescs.withUnsafeBufferPointer { bodyBuffer in
            constraintDescs.withUnsafeBufferPointer { constraintBuffer in
                guava_jolt_context_prepare(
                    nativeContext,
                    bodyBuffer.baseAddress,
                    bodyBuffer.count,
                    constraintBuffer.baseAddress,
                    constraintBuffer.count,
                    &stats
                )
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

        return PhysicsStepResult(
            bodyCount: Int(stats.body_count),
            constraintCount: Int(stats.constraint_count),
            contactCount: Int(stats.contact_count),
            writebacks: bodyStates
                .prefix(Int(stats.state_count))
                .compactMap { makeWriteback(from: $0, descriptorsByEntity: descriptorsByEntity) }
        )
    }

    public func reset() {
        if let context {
            guava_jolt_context_reset(context)
        }
    }

    private func makeBodyDesc(from descriptor: PhysicsBodyDescriptor) -> GuavaJoltBodyDesc {
        var flags: UInt32 = 0
        if descriptor.rigidBody?.allowSleep ?? false {
            flags |= Self.rigidBodyAllowSleepFlag
        }

        var boxHalfExtents = SIMD3<Float>.zero
        var sphereRadius: Float = 0
        var capsuleRadius: Float = 0
        var capsuleHalfHeight: Float = 0
        var layerID: UInt16 = 0
        var layerMask: UInt16 = .max

        if let collider = descriptor.collider {
            layerID = collider.layerID
            layerMask = collider.layerMask
            if collider.isTrigger {
                flags |= Self.colliderIsTriggerFlag
            }

            switch collider.shape {
            case let .box(halfExtents, _):
                flags |= Self.colliderHasBoxFlag
                boxHalfExtents = halfExtents
            case let .sphere(radius, _):
                flags |= Self.colliderHasSphereFlag
                sphereRadius = radius
            case let .capsule(radius, halfHeight, _):
                flags |= Self.colliderHasCapsuleFlag
                capsuleRadius = radius
                capsuleHalfHeight = halfHeight
            case .mesh:
                flags |= Self.colliderHasMeshFlag
            }
        }

        return GuavaJoltBodyDesc(
            entity_id: descriptor.entity.rawValue,
            motion_type: motionTypeValue(descriptor.rigidBody?.motionType ?? .static),
            flags: flags,
            position_x: descriptor.worldTransform.translation.x,
            position_y: descriptor.worldTransform.translation.y,
            position_z: descriptor.worldTransform.translation.z,
            rotation_x: 0,
            rotation_y: 0,
            rotation_z: 0,
            rotation_w: 1,
            linear_velocity_x: descriptor.rigidBody?.linearVelocity.x ?? 0,
            linear_velocity_y: descriptor.rigidBody?.linearVelocity.y ?? 0,
            linear_velocity_z: descriptor.rigidBody?.linearVelocity.z ?? 0,
            angular_velocity_x: descriptor.rigidBody?.angularVelocity.x ?? 0,
            angular_velocity_y: descriptor.rigidBody?.angularVelocity.y ?? 0,
            angular_velocity_z: descriptor.rigidBody?.angularVelocity.z ?? 0,
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
            layer_mask: layerMask
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
        GuavaJoltBodyState(
            entity_id: descriptor.entity.rawValue,
            position_x: descriptor.worldTransform.translation.x,
            position_y: descriptor.worldTransform.translation.y,
            position_z: descriptor.worldTransform.translation.z,
            rotation_x: 0,
            rotation_y: 0,
            rotation_z: 0,
            rotation_w: 1,
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
        case .slider:
            return 2
        case .distance:
            return 3
        }
    }

    private func makeWriteback(from state: GuavaJoltBodyState,
                               descriptorsByEntity: [UInt64: PhysicsBodyDescriptor]) -> PhysicsBodyWriteback? {
        guard let descriptor = descriptorsByEntity[state.entity_id],
              let rigidBody = descriptor.rigidBody,
              rigidBody.motionType != .static else {
            return nil
        }

        var matrix = descriptor.worldTransform.matrix
        matrix.columns.3 = SIMD4<Float>(state.position_x, state.position_y, state.position_z, 1)
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
}
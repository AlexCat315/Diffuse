import SceneRuntime
import Testing
import simd

private final class SelectionRecordingPhysicsBackend: PhysicsBackend, @unchecked Sendable {
    var prepareContexts: [PhysicsPrepareContext] = []

    var identifier: String {
        "recording"
    }

    func prepare(context: PhysicsPrepareContext) -> PhysicsPrepareResult {
        prepareContexts.append(context)
        return PhysicsPrepareResult(
            synchronizedBodies: context.activeBodies.count,
            synchronizedConstraints: context.activeConstraints.count
        )
    }

    func step(context: PhysicsStepContext) -> PhysicsStepResult {
        PhysicsStepResult(
            bodyCount: context.activeBodies.count,
            constraintCount: context.activeConstraints.count,
            contactCount: 0,
            writebacks: []
        )
    }

    func reset() {}
}

@Suite("PhysicsBackendSelection")
struct PhysicsBackendSelectionTests {
    @Test("configured backendKind selects the Jolt skeleton backend")
    func configuredBackendKindSelectsJolt() {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .jolt,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 1
            )
        )

        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: entity)
        _ = runtime.setComponent(RigidBody(), for: entity)
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
            for: entity
        )

        let report = runtime.tick(deltaTime: 1.0 / 60.0)

        #expect(report.physicsBackendIdentifier == "jolt")
        #expect(runtime.physicsFrameState.backendIdentifier == "jolt")
        #expect(report.physicsBodyCount == 1)
        #expect(report.physicsConstraintCount == 0)
    }

    @Test("manual backend override still wins over backendKind")
    func manualBackendOverrideWinsOverConfiguredKind() {
        var runtime = SceneRuntime()
        let backend = SelectionRecordingPhysicsBackend()
        runtime.setPhysicsBackend(backend)
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .jolt,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 1
            )
        )

        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: entity)
        _ = runtime.setComponent(RigidBody(), for: entity)
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.5, center: .zero)),
            for: entity
        )

        let report = runtime.tick(deltaTime: 1.0 / 60.0)

        #expect(report.physicsBackendIdentifier == "recording")
        #expect(backend.prepareContexts.count == 1)
    }

    @Test("configured Jolt backend writes stepped body state back into SceneRuntime")
    func configuredJoltBackendWritesBackSteppedBodyState() {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .jolt,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 1,
                allowSleep: false
            )
        )

        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: entity)
        _ = runtime.setComponent(
            RigidBody(
                motionType: .dynamic,
                mass: 1,
                linearVelocity: .zero,
                angularVelocity: .zero,
                gravityScale: 1,
                linearDamping: 0,
                angularDamping: 0,
                allowSleep: false,
                isSleeping: false
            ),
            for: entity
        )
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.5, center: .zero)),
            for: entity
        )

        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        let expectedVelocityY = Float(-9.81 / 60.0)
        let expectedPositionY = expectedVelocityY / 60.0

        #expect(report.physicsBackendIdentifier == "jolt")
        #expect(report.physicsWritebackCount == 1)
        #expect(abs((runtime.worldTransform(for: entity)?.translation.y ?? 0) - expectedPositionY) < 0.000_01)
        #expect(abs((runtime.component(RigidBody.self, for: entity)?.linearVelocity.y ?? 0) - expectedVelocityY) < 0.000_01)
        #expect(runtime.component(RigidBody.self, for: entity)?.isSleeping == false)
    }

    @Test("configured Jolt backend writes stepped body rotation back into SceneRuntime")
    func configuredJoltBackendWritesBackSteppedBodyRotation() {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .jolt,
                gravity: .zero,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 1,
                allowSleep: false
            )
        )

        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: entity)
        _ = runtime.setComponent(
            RigidBody(
                motionType: .dynamic,
                mass: 1,
                linearVelocity: .zero,
                angularVelocity: SIMD3<Float>(0, .pi, 0),
                gravityScale: 0,
                linearDamping: 0,
                angularDamping: 0,
                allowSleep: false,
                isSleeping: false
            ),
            for: entity
        )
        _ = runtime.setComponent(
            Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)),
            for: entity
        )

        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        let expectedRotation = simd_quatf(angle: .pi / 60.0, axis: SIMD3<Float>(0, 1, 0))
        let actualRotation = quaternion(from: runtime.worldTransform(for: entity)?.matrix ?? matrix_identity_float4x4)
        let alignment = abs(simd_dot(expectedRotation.vector, actualRotation.vector))

        #expect(report.physicsBackendIdentifier == "jolt")
        #expect(report.physicsWritebackCount == 1)
        #expect(alignment > 0.999_99)
        #expect(runtime.component(RigidBody.self, for: entity)?.angularVelocity == SIMD3<Float>(0, .pi, 0))
    }

    @Test("configured Jolt backend integrates runtime forces and impulses")
    func configuredJoltBackendIntegratesRuntimeForcesAndImpulses() {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .jolt,
                gravity: .zero,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 1,
                allowSleep: false
            )
        )

        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: entity)
        _ = runtime.setComponent(
            RigidBody(
                motionType: .dynamic,
                mass: 2,
                linearVelocity: .zero,
                angularVelocity: .zero,
                gravityScale: 0,
                linearDamping: 0,
                angularDamping: 0,
                allowSleep: false,
                isSleeping: true
            ),
            for: entity
        )
        _ = runtime.setComponent(
            Collider(
                shape: .sphere(radius: 0.5, center: .zero),
                material: PhysicsMaterial(friction: 0.9, restitution: 0.25, density: 2)
            ),
            for: entity
        )

        let appliedImpulse = runtime.applyLinearImpulse(SIMD3<Float>(2, 0, 0), to: entity)
        let appliedForce = runtime.applyForce(SIMD3<Float>(0, 120, 0), to: entity)
        let appliedTorque = runtime.applyTorque(SIMD3<Float>(0, 0, 120), to: entity)
        #expect(appliedImpulse)
        #expect(appliedForce)
        #expect(appliedTorque)

        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        let body = runtime.component(RigidBody.self, for: entity)

        #expect(report.physicsBackendIdentifier == "jolt")
        #expect(report.physicsWritebackCount == 1)
        #expect(abs((body?.linearVelocity.x ?? 0) - 1) < 0.000_1)
        #expect(abs((body?.linearVelocity.y ?? 0) - 1) < 0.000_1)
        #expect(abs((body?.angularVelocity.z ?? 0) - 1) < 0.000_1)
        #expect(body?.accumulatedForce == .zero)
        #expect(body?.accumulatedTorque == .zero)
        #expect(body?.isSleeping == false)
        #expect(abs((runtime.worldTransform(for: entity)?.translation.x ?? 0) - Float(1.0 / 60.0)) < 0.000_1)
        #expect(abs((runtime.worldTransform(for: entity)?.translation.y ?? 0) - Float(1.0 / 60.0)) < 0.000_1)
        #expect(runtime.component(Collider.self, for: entity)?.material == PhysicsMaterial(friction: 0.9, restitution: 0.25, density: 2))
    }

    @Test("configured Jolt backend applies distance constraints between active bodies")
    func configuredJoltBackendAppliesDistanceConstraint() {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .jolt,
                gravity: .zero,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 1,
                allowSleep: false
            )
        )

        let anchor = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: anchor)
        _ = runtime.setComponent(
            RigidBody(
                motionType: .static,
                mass: 0,
                linearVelocity: .zero,
                angularVelocity: .zero,
                gravityScale: 0,
                linearDamping: 0,
                angularDamping: 0,
                allowSleep: false,
                isSleeping: false
            ),
            for: anchor
        )
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.5, center: .zero)),
            for: anchor
        )

        let follower = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(6, 0, 0)), for: follower)
        _ = runtime.setComponent(
            RigidBody(
                motionType: .dynamic,
                mass: 1,
                linearVelocity: .zero,
                angularVelocity: .zero,
                gravityScale: 0,
                linearDamping: 0,
                angularDamping: 0,
                allowSleep: false,
                isSleeping: false
            ),
            for: follower
        )
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.5, center: .zero)),
            for: follower
        )

        let constraintEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: constraintEntity)
        _ = runtime.setComponent(
            Constraint(
                constraintType: .distance,
                entityA: anchor,
                entityB: follower,
                minLimit: 0,
                maxLimit: 2,
                isEnabled: true
            ),
            for: constraintEntity
        )

        let report = runtime.tick(deltaTime: 1.0 / 60.0)

        #expect(report.physicsBackendIdentifier == "jolt")
        #expect(report.physicsConstraintCount == 1)
        #expect(runtime.worldTransform(for: anchor)?.translation == .zero)
        #expect(abs((runtime.worldTransform(for: follower)?.translation.x ?? 0) - 2) < 0.000_1)
    }

    @Test("configured Jolt backend applies point-to-point constraints between active bodies")
    func configuredJoltBackendAppliesPointToPointConstraint() {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .jolt,
                gravity: .zero,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 1,
                allowSleep: false
            )
        )

        let anchor = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: anchor)
        _ = runtime.setComponent(
            RigidBody(
                motionType: .static,
                mass: 0,
                linearVelocity: .zero,
                angularVelocity: .zero,
                gravityScale: 0,
                linearDamping: 0,
                angularDamping: 0,
                allowSleep: false,
                isSleeping: false
            ),
            for: anchor
        )
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.5, center: .zero)),
            for: anchor
        )

        let follower = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(5, 0, 0)), for: follower)
        _ = runtime.setComponent(
            RigidBody(
                motionType: .dynamic,
                mass: 1,
                linearVelocity: .zero,
                angularVelocity: .zero,
                gravityScale: 0,
                linearDamping: 0,
                angularDamping: 0,
                allowSleep: false,
                isSleeping: false
            ),
            for: follower
        )
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.5, center: .zero)),
            for: follower
        )

        let constraintEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: constraintEntity)
        _ = runtime.setComponent(
            Constraint(
                constraintType: .pointToPoint,
                entityA: anchor,
                entityB: follower,
                pivotA: SIMD3<Float>(1, 0, 0),
                pivotB: SIMD3<Float>(-1, 0, 0),
                isEnabled: true
            ),
            for: constraintEntity
        )

        let report = runtime.tick(deltaTime: 1.0 / 60.0)

        #expect(report.physicsBackendIdentifier == "jolt")
        #expect(report.physicsConstraintCount == 1)
        #expect(runtime.worldTransform(for: anchor)?.translation == .zero)
        #expect(abs((runtime.worldTransform(for: follower)?.translation.x ?? 0) - 2) < 0.000_1)
    }

    @Test("configured Jolt backend adds velocity-layer response for distance constraints")
    func configuredJoltBackendAddsVelocityLayerResponseForDistanceConstraint() {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .jolt,
                gravity: .zero,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 1,
                allowSleep: false
            )
        )

        let bodyA = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: bodyA)
        _ = runtime.setComponent(
            RigidBody(
                motionType: .dynamic,
                mass: 1,
                linearVelocity: SIMD3<Float>(1, 0, 0),
                angularVelocity: .zero,
                gravityScale: 0,
                linearDamping: 0,
                angularDamping: 0,
                allowSleep: false,
                isSleeping: false
            ),
            for: bodyA
        )
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.5, center: .zero)),
            for: bodyA
        )

        let bodyB = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(6, 0, 0)), for: bodyB)
        _ = runtime.setComponent(
            RigidBody(
                motionType: .dynamic,
                mass: 1,
                linearVelocity: SIMD3<Float>(5, 0, 0),
                angularVelocity: .zero,
                gravityScale: 0,
                linearDamping: 0,
                angularDamping: 0,
                allowSleep: false,
                isSleeping: false
            ),
            for: bodyB
        )
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.5, center: .zero)),
            for: bodyB
        )

        let constraintEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: constraintEntity)
        _ = runtime.setComponent(
            Constraint(
                constraintType: .distance,
                entityA: bodyA,
                entityB: bodyB,
                minLimit: 0,
                maxLimit: 2,
                isEnabled: true
            ),
            for: constraintEntity
        )

        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        let positionA = runtime.worldTransform(for: bodyA)?.translation.x ?? 0
        let positionB = runtime.worldTransform(for: bodyB)?.translation.x ?? 0

        #expect(report.physicsBackendIdentifier == "jolt")
        #expect(report.physicsConstraintCount == 1)
        #expect(abs((positionB - positionA) - 2) < 0.000_1)
        #expect(abs((runtime.component(RigidBody.self, for: bodyA)?.linearVelocity.x ?? 0) - 3) < 0.000_1)
        #expect(abs((runtime.component(RigidBody.self, for: bodyB)?.linearVelocity.x ?? 0) - 3) < 0.000_1)
    }

    @Test("configured Jolt backend applies slider constraints between active bodies")
    func configuredJoltBackendAppliesSliderConstraint() {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .jolt,
                gravity: .zero,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 1,
                allowSleep: false
            )
        )

        let anchor = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: anchor)
        _ = runtime.setComponent(
            RigidBody(
                motionType: .static,
                mass: 0,
                linearVelocity: .zero,
                angularVelocity: .zero,
                gravityScale: 0,
                linearDamping: 0,
                angularDamping: 0,
                allowSleep: false,
                isSleeping: false
            ),
            for: anchor
        )
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.5, center: .zero)),
            for: anchor
        )

        let follower = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(2, 2, 0)), for: follower)
        _ = runtime.setComponent(
            RigidBody(
                motionType: .dynamic,
                mass: 1,
                linearVelocity: SIMD3<Float>(1, -3, 0),
                angularVelocity: .zero,
                gravityScale: 0,
                linearDamping: 0,
                angularDamping: 0,
                allowSleep: false,
                isSleeping: false
            ),
            for: follower
        )
        _ = runtime.setComponent(
            Collider(shape: .sphere(radius: 0.5, center: .zero)),
            for: follower
        )

        let constraintEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform.identity, for: constraintEntity)
        _ = runtime.setComponent(
            Constraint(
                constraintType: .slider,
                entityA: anchor,
                entityB: follower,
                axisA: SIMD3<Float>(1, 0, 0),
                axisB: SIMD3<Float>(1, 0, 0),
                minLimit: 1,
                maxLimit: 3,
                isEnabled: true
            ),
            for: constraintEntity
        )

        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        let expectedX: Float = 2 + (1.0 / 60.0)

        #expect(report.physicsBackendIdentifier == "jolt")
        #expect(report.physicsConstraintCount == 1)
        #expect(abs((runtime.worldTransform(for: follower)?.translation.x ?? 0) - expectedX) < 0.000_1)
        #expect(abs((runtime.worldTransform(for: follower)?.translation.y ?? 0) - 0) < 0.000_1)
        #expect(abs((runtime.component(RigidBody.self, for: follower)?.linearVelocity.x ?? 0) - 1) < 0.000_1)
        #expect(abs((runtime.component(RigidBody.self, for: follower)?.linearVelocity.y ?? 0) - 0) < 0.000_1)
    }
}

private func quaternion(from matrix: simd_float4x4) -> simd_quatf {
    let rotationMatrix = simd_float3x3(columns: (
        SIMD3<Float>(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
        SIMD3<Float>(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
        SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
    ))
    return simd_quatf(rotationMatrix)
}

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
}
import SceneRuntime
import SIMDCompat
import Testing

@Suite("AdvancedRigidBody")
struct AdvancedRigidBodyTests {
    private func runtime() -> SceneRuntime {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(
            PhysicsSettingsResource(
                simulationMode: .play,
                backendKind: .jolt,
                fixedTimeStepSeconds: 1.0 / 60.0,
                maxSubstepsPerFrame: 1
            )
        )
        return runtime
    }

    @Test("axis locks and maximum velocity reach Jolt")
    func locksAndVelocityLimit() {
        var runtime = runtime()
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 3, 0)), for: entity)
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 0.5, center: .zero)), for: entity)
        _ = runtime.setComponent(
            RigidBody(
                linearVelocity: SIMD3<Float>(100, 0, 0),
                axisLocks: [.translationY],
                maxLinearVelocity: 2
            ),
            for: entity
        )

        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        let body = runtime.component(RigidBody.self, for: entity)
        #expect(abs((body?.linearVelocity.x ?? 0)) <= 2.01)
        #expect(abs((runtime.worldTransform(for: entity)?.translation.y ?? 0) - 3) < 0.001)
    }

    @Test("kinematic target is solved over the fixed step")
    func kinematicTarget() {
        var runtime = runtime()
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(.identity, for: entity)
        _ = runtime.setComponent(Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)), for: entity)
        _ = runtime.setComponent(
            RigidBody(
                motionType: .kinematic,
                kinematicTarget: PhysicsKinematicTarget(position: SIMD3<Float>(3, 0, 0))
            ),
            for: entity
        )

        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(abs((runtime.worldTransform(for: entity)?.translation.x ?? 0) - 3) < 0.01)
    }

    @Test("point impulse produces linear and angular response")
    func pointImpulse() {
        var runtime = runtime()
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(.identity, for: entity)
        _ = runtime.setComponent(Collider(shape: .box(halfExtents: SIMD3<Float>(0.5, 0.5, 0.5), center: .zero)), for: entity)
        _ = runtime.setComponent(RigidBody(), for: entity)
        let applied = runtime.applyLinearImpulse(
            SIMD3<Float>(2, 0, 0),
            at: SIMD3<Float>(0, 1, 0),
            to: entity
        )
        #expect(applied)

        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        let body = runtime.component(RigidBody.self, for: entity)
        #expect((body?.linearVelocity.x ?? 0) > 0)
        #expect((body?.angularVelocity.z ?? 0) < 0)
    }
}

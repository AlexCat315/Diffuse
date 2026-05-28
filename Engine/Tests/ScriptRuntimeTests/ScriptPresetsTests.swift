import SceneRuntime
import ScriptRuntime
import Testing
import SIMDCompat

@Suite("ScriptPresets")
struct ScriptPresetsTests {

    // MARK: - Rotator

    @Test("rotator applies angular velocity each frame")
    func rotatorAppliesAngularVelocity() {
        var runtime = SceneRuntime()
        let scripts = ScriptRuntime()
        let rotScript = scripts.register(Script.rotator(speed: SIMD3<Float>(0, .pi, 0)))
        runtime.setScriptDriver(scripts)

        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(matrix: matrix_identity_float4x4), for: entity)
        _ = runtime.setComponent(ScriptComponent(rotScript), for: entity)

        // Half second at pi rad/s around Y = 90 degrees. +90° Y rotation maps -Z to -X.
        _ = runtime.tick(deltaTime: 0.5)

        let t = runtime.localTransform(for: entity)
        #expect(t != nil)
        let forward = t!.rotation.act(SIMD3<Float>(0, 0, -1))
        #expect(abs(forward.x - (-1.0)) < 0.01)
        #expect(abs(forward.z) < 0.01)
    }

    // MARK: - Oscillator

    @Test("oscillator moves entity sinusoidally along axis")
    func oscillatorMovesSinusoidally() {
        var runtime = SceneRuntime()
        let scripts = ScriptRuntime()
        let oscScript = scripts.register(Script.oscillator(
            axis: SIMD3<Float>(0, 1, 0),
            amplitude: 2.0,
            frequency: 1.0
        ))
        runtime.setScriptDriver(scripts)

        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 1, 0)), for: entity)
        _ = runtime.setComponent(ScriptComponent(oscScript), for: entity)

        // At t=0.25 (quarter period), sin(pi/2)=1, so offset = (0,2,0)
        _ = runtime.tick(deltaTime: 0.25)
        let t1 = runtime.localTransform(for: entity)
        #expect(t1 != nil)
        #expect(abs(t1!.translation.y - 3.0) < 0.01)

        // At t=0.75 (3/4 period), sin(3pi/2)=-1, offset = (0,-2,0)
        _ = runtime.tick(deltaTime: 0.5)
        let t2 = runtime.localTransform(for: entity)
        #expect(t2 != nil)
        #expect(abs(t2!.translation.y - (-1.0)) < 0.01)
    }

    // MARK: - Follower

    @Test("follower moves entity toward target")
    func followerMovesTowardTarget() {
        var runtime = SceneRuntime()
        let scripts = ScriptRuntime()

        let target = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(10, 0, 0)), for: target)

        let followerEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: followerEntity)

        let followScript = scripts.register(Script.follower(target: target, speed: 10.0, arrivalRadius: 0.05))
        _ = runtime.setComponent(ScriptComponent(followScript), for: followerEntity)
        runtime.setScriptDriver(scripts)

        // After 0.5s at speed 10, should move 5 units toward target
        _ = runtime.tick(deltaTime: 0.5)
        let t1 = runtime.localTransform(for: followerEntity)
        #expect(t1 != nil)
        #expect(t1!.translation.x > 0)
        #expect(t1!.translation.x < 10)
    }

    @Test("follower stops at arrival radius")
    func followerStopsAtArrivalRadius() {
        var runtime = SceneRuntime()
        let scripts = ScriptRuntime()

        let target = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0.02, 0, 0)), for: target)

        let followerEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: followerEntity)

        let followScript = scripts.register(Script.follower(target: target, speed: 10.0, arrivalRadius: 0.1))
        _ = runtime.setComponent(ScriptComponent(followScript), for: followerEntity)
        runtime.setScriptDriver(scripts)

        _ = runtime.tick(deltaTime: 1.0)
        let t1 = runtime.localTransform(for: followerEntity)
        #expect(t1 != nil)
        // Should not have moved since within arrival radius
        #expect(t1!.translation.x == 0)
    }

    // MARK: - LookAt

    @Test("lookAt rotates entity to face target")
    func lookAtRotatesToFaceTarget() {
        var runtime = SceneRuntime()
        let scripts = ScriptRuntime()

        let target = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 0, -5)), for: target)

        let looker = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(matrix: matrix_identity_float4x4), for: looker)

        let lookScript = scripts.register(Script.lookAtTarget(target))
        _ = runtime.setComponent(ScriptComponent(lookScript), for: looker)
        runtime.setScriptDriver(scripts)

        _ = runtime.tick(deltaTime: 0.1)

        let t = runtime.localTransform(for: looker)
        #expect(t != nil)
        // Forward (-Z) should now point toward target at (0,0,-5)
        let forward = t!.rotation.act(SIMD3<Float>(0, 0, -1))
        #expect(forward.z < -0.99)
    }

    // MARK: - DestroyAfter

    @Test("destroyAfter removes entity after elapsed time")
    func destroyAfterRemovesEntity() {
        var runtime = SceneRuntime()
        let scripts = ScriptRuntime()

        let entity = runtime.createEntity()
        let destroyScript = scripts.register(Script.destroyAfter(1.0))
        _ = runtime.setComponent(ScriptComponent(destroyScript), for: entity)
        runtime.setScriptDriver(scripts)

        // Tick for less than lifetime — entity still alive
        _ = runtime.tick(deltaTime: 0.5)
        #expect(runtime.contains(entity))

        // Tick past lifetime — script enqueues destroy
        _ = runtime.tick(deltaTime: 0.6)
        // Third tick processes the enqueued destroy command
        _ = runtime.tick(deltaTime: 0.01)
        #expect(!runtime.contains(entity))
    }

    // MARK: - Mover

    @Test("mover translates entity at constant velocity")
    func moverTranslatesEntity() {
        var runtime = SceneRuntime()
        let scripts = ScriptRuntime()

        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: .zero), for: entity)
        let moveScript = scripts.register(Script.mover(velocity: SIMD3<Float>(3, 0, 0)))
        _ = runtime.setComponent(ScriptComponent(moveScript), for: entity)
        runtime.setScriptDriver(scripts)

        _ = runtime.tick(deltaTime: 2.0)

        let t = runtime.localTransform(for: entity)
        #expect(t != nil)
        #expect(abs(t!.translation.x - 6.0) < 0.01)
    }
}

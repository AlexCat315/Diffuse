import SceneRuntime
import SIMDCompat
import Testing

@Suite("PhysicsJoint v2")
struct PhysicsJointTests {
    @Test("joint is resent when a connected body must be recreated")
    func jointSurvivesConnectedBodyRecreation() {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: .preferred,
            gravity: .zero,
            fixedTimeStepSeconds: 1.0 / 60.0,
            maxSubstepsPerFrame: 1,
            allowSleep: false,
            capacity: PhysicsCapacitySettings(workerThreadCount: 1)
        ))
        let first = runtime.createEntity()
        let second = runtime.createEntity()
        for (entity, x) in [(first, Float(0)), (second, Float(1))] {
            _ = runtime.setLocalTransform(
                LocalTransform(translation: SIMD3<Float>(x, 0, 0)), for: entity)
            _ = runtime.setComponent(RigidBody(gravityScale: 0, allowSleep: false), for: entity)
            _ = runtime.setComponent(Collider(shape: .sphere(radius: 0.4, center: .zero)), for: entity)
        }
        let joint = runtime.createEntity()
        _ = runtime.setLocalTransform(.identity, for: joint)
        _ = runtime.setComponent(PhysicsJoint(
            configuration: .point,
            entityA: first,
            entityB: second
        ), for: joint)

        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(runtime.physicsFrameState.synchronization.constraints == 1)
        _ = runtime.updateComponent(Collider.self, for: first) {
            $0.shape = .sphere(radius: 0.6, center: .zero)
        }
        let recreated = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(recreated.physics.error == nil)
        #expect(runtime.physicsFrameState.synchronization.bodies == 1)
        #expect(runtime.physicsFrameState.synchronization.constraints == 1)

        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(runtime.physicsFrameState.synchronization.bodies == 0)
        #expect(runtime.physicsFrameState.synchronization.constraints == 0)
    }

    @Test("joint break thresholds emit events and disable the authored joint")
    func breakEvent() throws {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: .preferred,
            gravity: .zero,
            fixedTimeStepSeconds: 1.0 / 60.0,
            maxSubstepsPerFrame: 1,
            allowSleep: false
        ))
        let anchor = runtime.createEntity()
        _ = runtime.setLocalTransform(.identity, for: anchor)
        _ = runtime.setComponent(RigidBody(motionType: .static), for: anchor)
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 0.25, center: .zero)), for: anchor)
        let body = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 3, 0)), for: body)
        _ = runtime.setComponent(RigidBody(
            motionType: .dynamic, mass: 1, gravityScale: 0, allowSleep: false
        ), for: body)
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 0.25, center: .zero)), for: body)
        let jointEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(.identity, for: jointEntity)
        _ = runtime.setComponent(PhysicsJoint(
            configuration: .distance(DistanceJointConfiguration(maximumDistance: 0.5)),
            entityA: anchor,
            entityB: body,
            breakForce: 0.001
        ), for: jointEntity)

        var event: PhysicsJointBreakEvent?
        for _ in 0..<30 where event == nil {
            _ = runtime.tick(deltaTime: 1.0 / 60.0)
            event = runtime.physicsEventFrame.jointBreaks.first
        }
        let recordedEvent = try #require(event)
        #expect(recordedEvent.jointEntity == jointEntity)
        #expect(recordedEvent.force > 0.001)
        #expect(runtime.component(PhysicsJoint.self, for: jointEntity)?.isEnabled == false)
    }

    @Test("Natsel creates cone and six-DOF joints from typed configurations", arguments: [
        PhysicsJointConfiguration.cone(ConeJointConfiguration(
            halfConeAngle: 0.4,
            minimumTwistAngle: -0.2,
            maximumTwistAngle: 0.2,
            spring: PhysicsJointSpring(frequency: 2, damping: 0.5)
        )),
        PhysicsJointConfiguration.sixDOF(SixDOFJointConfiguration(
            linearMinimum: SIMD3<Float>(-0.25, 0, 0),
            linearMaximum: SIMD3<Float>(0.25, 0, 0),
            angularMinimum: SIMD3<Float>(-0.1, -0.2, -0.3),
            angularMaximum: SIMD3<Float>(0.1, 0.2, 0.3),
            linearMotor: PhysicsJointMotor(mode: .position, maxForce: 10),
            angularMotor: PhysicsJointMotor(mode: .velocity, targetVelocity: 0.1, maxForce: 10)
        )),
    ])
    func createsTypedJoints(configuration: PhysicsJointConfiguration) {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: .preferred,
            gravity: .zero,
            fixedTimeStepSeconds: 1.0 / 60.0,
            maxSubstepsPerFrame: 1,
            allowSleep: false
        ))
        let anchor = runtime.createEntity()
        _ = runtime.setLocalTransform(.identity, for: anchor)
        _ = runtime.setComponent(RigidBody(motionType: .static), for: anchor)
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 0.25, center: .zero)), for: anchor)

        let body = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: SIMD3<Float>(0, 1, 0)), for: body)
        _ = runtime.setComponent(RigidBody(
            motionType: .dynamic,
            mass: 1,
            gravityScale: 0,
            allowSleep: false
        ), for: body)
        _ = runtime.setComponent(Collider(shape: .sphere(radius: 0.25, center: .zero)), for: body)

        let jointEntity = runtime.createEntity()
        _ = runtime.setLocalTransform(.identity, for: jointEntity)
        _ = runtime.setComponent(PhysicsJoint(
            configuration: configuration,
            entityA: anchor,
            entityB: body
        ), for: jointEntity)

        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physics.error == nil)
        #expect(report.physics.constraintCount == 1)
        #expect(runtime.physicsFrameState.counts.constraints == 1)
    }
}

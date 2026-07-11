import CJoltBridge
import SceneRuntime
import SIMDCompat
import Testing

@Suite("PhysicsJoint v2")
struct PhysicsJointTests {
    @Test("C ABI v2 publishes exact physics structure sizes and stable leading offsets")
    func abiLayout() {
        var layout = GuavaJoltABILayout()
        #expect(guava_jolt_bridge_abi_version() == 2)
        #expect(guava_jolt_bridge_get_abi_layout(&layout))
        #expect(layout.struct_size == UInt32(MemoryLayout<GuavaJoltABILayout>.size))
        #expect(layout.body_desc_size == UInt32(MemoryLayout<GuavaJoltBodyDesc>.size))
        #expect(layout.constraint_desc_size == UInt32(MemoryLayout<GuavaJoltConstraintDesc>.size))
        #expect(layout.contact_event_size == UInt32(MemoryLayout<GuavaJoltContactEvent>.size))
        #expect(layout.joint_break_event_size == UInt32(MemoryLayout<GuavaJoltJointBreakEvent>.size))
        #expect(MemoryLayout<GuavaJoltConstraintDesc>.offset(of: \.entity_id) == 0)
        #expect(MemoryLayout<GuavaJoltConstraintDesc>.offset(of: \.entity_a) == 8)
        #expect(MemoryLayout<GuavaJoltConstraintDesc>.offset(of: \.entity_b) == 16)
        #expect(MemoryLayout<GuavaJoltJointBreakEvent>.offset(of: \.joint_entity) == 0)
    }

    @Test("joint break thresholds emit events and disable the authored joint")
    func breakEvent() throws {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: .jolt,
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

    @Test("Jolt creates cone and six-DOF joints from typed configurations", arguments: [
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
            backendKind: .jolt,
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
        #expect(report.physicsError == nil)
        #expect(report.physicsConstraintCount == 1)
        #expect(runtime.physicsFrameState.constraintCount == 1)
    }
}

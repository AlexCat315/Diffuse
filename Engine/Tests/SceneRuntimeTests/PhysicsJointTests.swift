import CJoltBridge
import SceneRuntime
import SIMDCompat
import Testing

@Suite("PhysicsJoint v2")
struct PhysicsJointTests {
    @Test("C ABI v2 publishes exact physics structure sizes and stable leading offsets")
    func abiLayout() {
        var layout = GuavaJoltABILayout()
        var vehicleLayout = GuavaJoltVehicleABILayout()
        vehicleLayout.struct_size = UInt32(MemoryLayout<GuavaJoltVehicleABILayout>.size)
        #expect(guava_jolt_bridge_abi_version() == 2)
        #expect(guava_jolt_bridge_get_abi_layout(&layout))
        #expect(guava_jolt_bridge_get_vehicle_abi_layout(&vehicleLayout))
        #expect(layout.struct_size == UInt32(MemoryLayout<GuavaJoltABILayout>.size))
        #expect(layout.body_desc_size == UInt32(MemoryLayout<GuavaJoltBodyDesc>.size))
        #expect(layout.constraint_desc_size == UInt32(MemoryLayout<GuavaJoltConstraintDesc>.size))
        #expect(layout.contact_event_size == UInt32(MemoryLayout<GuavaJoltContactEvent>.size))
        #expect(layout.joint_break_event_size == UInt32(MemoryLayout<GuavaJoltJointBreakEvent>.size))
        #expect(layout.context_config_size == UInt32(MemoryLayout<GuavaJoltContextConfig>.size))
        #expect(MemoryLayout<GuavaJoltConstraintDesc>.offset(of: \.entity_id) == 0)
        #expect(MemoryLayout<GuavaJoltConstraintDesc>.offset(of: \.entity_a) == 8)
        #expect(MemoryLayout<GuavaJoltConstraintDesc>.offset(of: \.entity_b) == 16)
        #expect(MemoryLayout<GuavaJoltJointBreakEvent>.offset(of: \.joint_entity) == 0)
        #expect(vehicleLayout.abi_version == 2)
        #expect(vehicleLayout.struct_size == UInt32(MemoryLayout<GuavaJoltVehicleABILayout>.size))
        #expect(vehicleLayout.vehicle_desc_size == UInt32(MemoryLayout<GuavaJoltVehicleDesc>.size))
        #expect(vehicleLayout.wheel_desc_size == UInt32(MemoryLayout<GuavaJoltVehicleWheelDesc>.size))
        #expect(vehicleLayout.differential_desc_size == UInt32(MemoryLayout<GuavaJoltVehicleDifferentialDesc>.size))
        #expect(vehicleLayout.anti_roll_bar_desc_size == UInt32(MemoryLayout<GuavaJoltVehicleAntiRollBarDesc>.size))
        #expect(vehicleLayout.command_size == UInt32(MemoryLayout<GuavaJoltVehicleCommand>.size))
        #expect(vehicleLayout.state_size == UInt32(MemoryLayout<GuavaJoltVehicleState>.size))
        #expect(vehicleLayout.wheel_state_size == UInt32(MemoryLayout<GuavaJoltVehicleWheelState>.size))
        #expect(vehicleLayout.sync_stats_size == UInt32(MemoryLayout<GuavaJoltVehicleSyncStats>.size))
        #expect(MemoryLayout<GuavaJoltVehicleDesc>.offset(of: \.entity_id) == 0)
        #expect(MemoryLayout<GuavaJoltVehicleCommand>.offset(of: \.entity_id) == 0)

        var invalidVehicleLayout = GuavaJoltVehicleABILayout()
        invalidVehicleLayout.struct_size = 0
        #expect(!guava_jolt_bridge_get_vehicle_abi_layout(&invalidVehicleLayout))
    }

    @Test("C ABI rejects malformed context capacity configuration")
    func invalidContextConfiguration() {
        var config = GuavaJoltContextConfig()
        config.struct_size = UInt32(MemoryLayout<GuavaJoltContextConfig>.size)
        config.max_bodies = 0
        config.max_body_pairs = 64
        config.max_contact_constraints = 64
        config.temp_allocator_bytes = 1_024 * 1_024
        #expect(guava_jolt_context_create_with_config(&config) == nil)
    }

    @Test("joint is resent when a connected body must be recreated")
    func jointSurvivesConnectedBodyRecreation() {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: .jolt,
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
        #expect(runtime.physicsFrameState.synchronizedConstraintCount == 1)
        _ = runtime.updateComponent(Collider.self, for: first) {
            $0.shape = .sphere(radius: 0.6, center: .zero)
        }
        let recreated = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(recreated.physicsError == nil)
        #expect(runtime.physicsFrameState.synchronizedBodyCount == 1)
        #expect(runtime.physicsFrameState.synchronizedConstraintCount == 1)

        _ = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(runtime.physicsFrameState.synchronizedBodyCount == 0)
        #expect(runtime.physicsFrameState.synchronizedConstraintCount == 0)
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

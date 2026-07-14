import SceneRuntime
import SIMDCompat
import Testing

@Suite("VehicleAcceptance")
struct VehicleAcceptanceTests {
    private func runtime() -> SceneRuntime {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: .jolt,
            fixedTimeStepSeconds: 1.0 / 60.0,
            maxSubstepsPerFrame: 1,
            allowSleep: false,
            capacity: PhysicsCapacitySettings(workerThreadCount: 1)
        ))
        return runtime
    }

    @discardableResult
    private func addStaticBox(
        to runtime: inout SceneRuntime,
        position: SIMD3<Float>,
        halfExtents: SIMD3<Float>,
        friction: Float = 1,
        rotation: simd_quatf? = nil
    ) -> EntityID {
        let entity = runtime.createEntity()
        var transform = LocalTransform(translation: position)
        if let rotation { transform = transform.withRotation(rotation) }
        _ = runtime.setLocalTransform(transform, for: entity)
        _ = runtime.setComponent(
            Collider(
                shape: .box(halfExtents: halfExtents, center: .zero),
                material: PhysicsMaterial(friction: friction, restitution: 0)
            ),
            for: entity
        )
        return entity
    }

    private func addCar(
        to runtime: inout SceneRuntime,
        position: SIMD3<Float> = SIMD3<Float>(0, 1, 0),
        maxTorque: Float = 900
    ) -> EntityID {
        let entity = runtime.createEntity()
        _ = runtime.setLocalTransform(LocalTransform(translation: position), for: entity)
        _ = runtime.setComponent(
            Collider(
                shape: .box(halfExtents: SIMD3<Float>(0.8, 0.2, 1.5), center: .zero),
                material: PhysicsMaterial(friction: 0.8, restitution: 0)
            ),
            for: entity
        )
        _ = runtime.setComponent(
            RigidBody(
                motionType: .dynamic,
                mass: 1_200,
                linearDamping: 0.02,
                angularDamping: 0.05,
                allowSleep: false,
                centerOfMassOverride: SIMD3<Float>(0, -0.3, 0)
            ),
            for: entity
        )
        _ = runtime.setComponent(
            Vehicle(engine: VehicleEngineConfiguration(maxTorque: maxTorque)),
            for: entity
        )
        return entity
    }

    private func tick(
        _ runtime: inout SceneRuntime,
        vehicle: EntityID,
        command: VehicleCommand,
        frames: Range<Int>
    ) {
        for frame in frames {
            runtime.submitVehicleCommand(command, for: vehicle)
            #expect(runtime.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            ).physicsError == nil)
        }
    }

    @Test("terrain friction changes longitudinal acceleration")
    func frictionMaterials() {
        func travelDistance(friction: Float) -> Float {
            var runtime = runtime()
            addStaticBox(
                to: &runtime,
                position: SIMD3<Float>(0, -0.5, 0),
                halfExtents: SIMD3<Float>(50, 0.5, 50),
                friction: friction
            )
            let car = addCar(to: &runtime)
            tick(&runtime, vehicle: car, command: VehicleCommand(), frames: 0..<90)
            let before = runtime.worldTransform(for: car)?.translation.z ?? 0
            tick(
                &runtime,
                vehicle: car,
                command: VehicleCommand(throttle: 1),
                frames: 90..<270
            )
            return (runtime.worldTransform(for: car)?.translation.z ?? 0) - before
        }

        let highFrictionDistance = travelDistance(friction: 1)
        let lowFrictionDistance = travelDistance(friction: 0.05)
        #expect(highFrictionDistance > lowFrictionDistance + 0.25)
    }

    @Test("vehicle climbs a ramp and becomes airborne after the lip")
    func rampAndJump() {
        var runtime = runtime()
        addStaticBox(
            to: &runtime,
            position: SIMD3<Float>(0, -0.5, -5),
            halfExtents: SIMD3<Float>(5, 0.5, 7)
        )
        addStaticBox(
            to: &runtime,
            position: SIMD3<Float>(0, 0.3, 4.5),
            halfExtents: SIMD3<Float>(3, 0.25, 3),
            rotation: simd_quatf(angle: -.pi / 12, axis: SIMD3<Float>(1, 0, 0))
        )
        let car = addCar(
            to: &runtime,
            position: SIMD3<Float>(0, 1, -3),
            maxTorque: 1_500
        )

        var hadGroundContact = false
        var becameAirborne = false
        var maxHeight: Float = -.greatestFiniteMagnitude
        for frame in 0..<600 {
            runtime.submitVehicleCommand(
                VehicleCommand(throttle: frame < 90 ? 0 : 1),
                for: car
            )
            #expect(runtime.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            ).physicsError == nil)
            let state = runtime.vehicleStateFrame.states[car]
            let hasContact = state?.wheels.contains(where: \.hasContact) == true
            hadGroundContact = hadGroundContact || hasContact
            becameAirborne = becameAirborne || (hadGroundContact && !hasContact && frame > 180)
            maxHeight = max(maxHeight, runtime.worldTransform(for: car)?.translation.y ?? 0)
        }

        #expect(maxHeight > 1.4)
        #expect(becameAirborne)
    }

    @Test("vehicle can reverse away after a chassis collision")
    func collisionRecovery() {
        var runtime = runtime()
        addStaticBox(
            to: &runtime,
            position: SIMD3<Float>(0, -0.5, 0),
            halfExtents: SIMD3<Float>(30, 0.5, 30)
        )
        let wall = addStaticBox(
            to: &runtime,
            position: SIMD3<Float>(0, 1, 6),
            halfExtents: SIMD3<Float>(3, 1, 0.5)
        )
        let car = addCar(to: &runtime, maxTorque: 1_500)
        tick(&runtime, vehicle: car, command: VehicleCommand(), frames: 0..<90)

        var hitWall = false
        for frame in 90..<420 {
            runtime.submitVehicleCommand(VehicleCommand(throttle: 1), for: car)
            let report = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: UInt64(frame))
            #expect(report.physicsError == nil)
            hitWall = hitWall || runtime.physicsEventFrame.contacts.contains { event in
                (event.entityA == car && event.entityB == wall)
                    || (event.entityA == wall && event.entityB == car)
            }
        }
        let collisionPosition = runtime.worldTransform(for: car)?.translation.z ?? 0
        tick(
            &runtime,
            vehicle: car,
            command: VehicleCommand(throttle: -1),
            frames: 420..<720
        )
        let recoveredPosition = runtime.worldTransform(for: car)?.translation.z ?? 0

        #expect(hitWall)
        #expect(collisionPosition < 6)
        #expect(recoveredPosition < collisionPosition - 0.5)
    }

    @Test("wheel contacts inherit a kinematic moving platform")
    func movingPlatform() {
        var runtime = runtime()
        let platform = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(0, -0.25, 0)), for: platform
        )
        _ = runtime.setComponent(
            Collider(
                shape: .box(halfExtents: SIMD3<Float>(4, 0.25, 4), center: .zero),
                material: PhysicsMaterial(friction: 1, restitution: 0)
            ),
            for: platform
        )
        _ = runtime.setComponent(RigidBody(motionType: .kinematic), for: platform)
        let car = addCar(to: &runtime)
        tick(&runtime, vehicle: car, command: VehicleCommand(), frames: 0..<120)
        #expect(runtime.vehicleStateFrame.states[car]?.wheels.contains {
            $0.contactEntity == platform
        } == true)

        let before = runtime.worldTransform(for: car)?.translation.x ?? 0
        for frame in 120..<300 {
            let targetX = Float(frame - 119) * 0.01
            _ = runtime.updateComponent(RigidBody.self, for: platform) {
                $0.kinematicTarget = PhysicsKinematicTarget(
                    position: SIMD3<Float>(targetX, -0.25, 0)
                )
            }
            runtime.submitVehicleCommand(VehicleCommand(), for: car)
            #expect(runtime.tick(
                deltaTime: 1.0 / 60.0,
                frameIndex: UInt64(frame)
            ).physicsError == nil)
        }
        let after = runtime.worldTransform(for: car)?.translation.x ?? 0

        #expect(after > before + 0.3)
        #expect(runtime.vehicleStateFrame.states[car]?.wheels.contains {
            $0.contactEntity == platform
        } == true)
    }
}

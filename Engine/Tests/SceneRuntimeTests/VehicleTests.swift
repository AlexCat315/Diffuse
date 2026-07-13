import SceneRuntime
import SIMDCompat
import Testing

@Suite("WheeledVehicle")
struct VehicleTests {
    private func makeRuntime() -> (runtime: SceneRuntime, vehicle: EntityID) {
        var runtime = SceneRuntime()
        runtime.setPhysicsSettings(PhysicsSettingsResource(
            simulationMode: .play,
            backendKind: .jolt,
            fixedTimeStepSeconds: 1.0 / 60.0,
            maxSubstepsPerFrame: 1,
            allowSleep: false,
            capacity: PhysicsCapacitySettings(workerThreadCount: 1)
        ))

        let ground = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(0, -0.5, 0)), for: ground
        )
        _ = runtime.setComponent(
            Collider(
                shape: .box(halfExtents: SIMD3<Float>(50, 0.5, 50), center: .zero),
                material: PhysicsMaterial(friction: 1, restitution: 0)
            ),
            for: ground
        )

        let vehicle = runtime.createEntity()
        _ = runtime.setLocalTransform(
            LocalTransform(translation: SIMD3<Float>(0, 1, 0)), for: vehicle
        )
        _ = runtime.setComponent(
            Collider(
                shape: .box(halfExtents: SIMD3<Float>(0.8, 0.2, 1.5), center: .zero),
                material: PhysicsMaterial(friction: 0.8, restitution: 0)
            ),
            for: vehicle
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
            for: vehicle
        )
        _ = runtime.setComponent(Vehicle(), for: vehicle)
        return (runtime, vehicle)
    }

    @Test("Jolt vehicle reports wheel contact and consumes current-frame throttle")
    func drivesAndReportsWheelState() {
        var (runtime, vehicle) = makeRuntime()
        for frame in 0..<90 {
            runtime.submitVehicleCommand(VehicleCommand(), for: vehicle)
            let report = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: UInt64(frame))
            #expect(report.physicsError == nil)
        }

        let settled = runtime.vehicleStateFrame.states[vehicle]
        #expect(settled?.wheels.count == 4)
        #expect(settled?.wheels.contains(where: \.hasContact) == true)
        let before = runtime.worldTransform(for: vehicle)?.translation.z ?? 0

        for frame in 90..<270 {
            runtime.submitVehicleCommand(VehicleCommand(throttle: 1), for: vehicle)
            let report = runtime.tick(deltaTime: 1.0 / 60.0, frameIndex: UInt64(frame))
            #expect(report.physicsError == nil)
        }

        let after = runtime.worldTransform(for: vehicle)?.translation.z ?? 0
        let state = runtime.vehicleStateFrame.states[vehicle]
        #expect(after > before + 1)
        #expect((state?.engineRPM ?? 0) > 1_000)
        #expect((state?.forwardSpeed ?? 0) > 0)
        #expect(state?.wheels.count == 4)
    }

    @Test("vehicle configuration is incrementally rebuilt and removal clears frame state")
    func incrementalRebuildAndRemoval() {
        var (runtime, vehicle) = makeRuntime()
        var report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physicsError == nil)
        #expect(runtime.vehicleStateFrame.states[vehicle]?.wheels.count == 4)

        _ = runtime.updateComponent(Vehicle.self, for: vehicle) {
            $0.engine.maxTorque = 900
        }
        report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physicsError == nil)
        #expect(runtime.vehicleStateFrame.states[vehicle]?.wheels.count == 4)

        _ = runtime.removeComponent(Vehicle.self, from: vehicle)
        report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physicsError == nil)
        #expect(runtime.vehicleStateFrame.states[vehicle] == nil)
    }

    @Test("recorded vehicle commands replay to identical wheel-state hashes")
    func commandRecordingReplay() {
        var (recordingRuntime, vehicle) = makeRuntime()
        recordingRuntime.beginPhysicsCommandRecording(maxFrames: 120)
        for frame in 0..<90 {
            let command = frame < 30
                ? VehicleCommand()
                : VehicleCommand(throttle: 0.8, steering: frame < 60 ? 0.15 : -0.1)
            recordingRuntime.submitVehicleCommand(command, for: vehicle)
            _ = recordingRuntime.tick(deltaTime: 1.0 / 60.0)
        }
        let tape = recordingRuntime.endPhysicsCommandRecording()
        let expectedState = recordingRuntime.vehicleStateFrame.states[vehicle]
        #expect(tape.frames.count == 90)
        #expect(tape.frames.contains { !$0.vehicleCommands.isEmpty })

        var (replayRuntime, replayVehicle) = makeRuntime()
        let replay = replayRuntime.replayPhysicsCommands(tape)
        #expect(replay.isDeterministic)
        #expect(replay.replayedFrameCount == 90)
        #expect(replayRuntime.vehicleStateFrame.states[replayVehicle] == expectedState)
    }

    @Test("invalid wheel configuration is surfaced as a native argument error")
    func invalidConfigurationReportsError() {
        var (runtime, vehicle) = makeRuntime()
        _ = runtime.setComponent(
            Vehicle(wheels: [], differentials: [], antiRollBars: []), for: vehicle
        )
        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physicsError?.code == .invalidArgument)
    }

    @Test("manual gear commands are checked against the configured transmission")
    func invalidManualGearReportsError() {
        var (runtime, vehicle) = makeRuntime()
        _ = runtime.updateComponent(Vehicle.self, for: vehicle) {
            $0.transmission = VehicleTransmissionConfiguration(
                mode: .manual,
                gearRatios: [2.5, 1.5],
                reverseGearRatios: [-2.8]
            )
        }
        runtime.submitVehicleCommand(
            VehicleCommand(throttle: 1, manualGear: 3),
            for: vehicle
        )

        let report = runtime.tick(deltaTime: 1.0 / 60.0)
        #expect(report.physicsError?.code == .invalidArgument)
    }

    @Test("vehicle configuration survives Scene v2 round-trip")
    func sceneRoundTrip() throws {
        var original = SceneRuntime()
        let entity = original.createEntity()
        let vehicle = Vehicle(
            engine: VehicleEngineConfiguration(maxTorque: 875, minRPM: 900, maxRPM: 7_200),
            transmission: VehicleTransmissionConfiguration(
                mode: .manual,
                gearRatios: [3.1, 1.9, 1.2],
                reverseGearRatios: [-3.0],
                clutchStrength: 14
            ),
            maxPitchRollAngle: .pi / 2
        )
        _ = original.setComponent(vehicle, for: entity)

        let data = try SceneSerializer.serialize(original)
        var restored = SceneRuntime()
        try SceneSerializer.deserialize(data, into: &restored)
        let restoredEntity = try #require(restored.entities().first)
        #expect(restored.component(Vehicle.self, for: restoredEntity) == vehicle)
    }
}

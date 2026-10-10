import Dispatch
import EngineKernel
import SIMDCompat

extension RuntimeWorldSchedule {
    // MARK: - Phases

    func applyCommands(
        _ commands: [RuntimeCommand],
        world: inout RuntimeWorld,
        into frame: inout RuntimeFrameContext
    ) {
        for command in commands {
            switch command {
            case .createEntity:
                frame.createdEntities.append(world.createEntity())
            case let .destroyEntity(entity):
                if world.destroyEntity(entity) {
                    frame.destroyedEntities.append(entity)
                }
            case let .setParent(parent, child):
                _ = world.setParent(parent, for: child)
            case let .setLocalTransform(entity, transform):
                _ = world.setLocalTransform(transform, for: entity)
            }
        }
    }

    mutating func runPrePhysicsScripts(
        world: inout RuntimeWorld,
        commands: inout RuntimeCommandBuffer,
        into frame: inout RuntimeFrameContext,
        deltaTimeSeconds: Double
    ) {
        let isReplaying = world.resource(PhysicsCommandReplayControlResource.self)?.isReplaying == true
        if !isReplaying, let scriptDriver {
            withUnsafeMutablePointer(to: &world) { worldPointer in
                withUnsafeMutablePointer(to: &commands) { commandPointer in
                    var scriptContext = RuntimeScriptPhaseContext(
                        world: worldPointer,
                        commands: commandPointer,
                        deltaTimeSeconds: deltaTimeSeconds,
                        physicsQueryScene: physicsQueryScene
                    )
                    scriptDriver.prepareFrame(context: &scriptContext)
                    scriptDriver.runPrePhysics(context: &scriptContext)
                }
            }
        }
        advanceDestructionPrePhysics(
            in: &world,
            deltaTimeSeconds: deltaTimeSeconds,
            frame: &frame.recording.destructionEvents
        )
        applyRagdollAnimationToBodies(in: &world)
        if world.hierarchyNeedsPropagation() {
            let report = world.propagateTransforms(using: jobSystem)
            frame.jobs.record(report, for: .inputAndPrePhysicsScripts)
        }
        frame.physicsSettings = world.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
        ensureConfiguredPhysicsBackend(kind: frame.physicsSettings.backendKind)
    }

    mutating func prepareFixedPhysics(
        world: inout RuntimeWorld,
        into frame: inout RuntimeFrameContext,
        deltaTimeSeconds: Double
    ) {
        guard frame.physicsSettings.simulationMode != .off else {
            resetDisabledPhysicsResources(world: &world)
            return
        }

        let physicsReadView = buildPhysicsReadView(in: world)
        let bodyCollection = collectPhysicsBodies(from: physicsReadView)
        let constraintCollection = collectPhysicsConstraints(from: physicsReadView)
        frame.descriptors.bodies = bodyCollection.bodies
        frame.descriptors.constraints = constraintCollection.constraints
        frame.descriptors.characters = collectPhysicsCharacters(from: physicsReadView)
        frame.descriptors.vehicles = collectPhysicsVehicles(from: physicsReadView)
        frame.descriptors.softBodies = collectPhysicsSoftBodies(from: physicsReadView)
        let activeSoftBodyEntities = Set(frame.descriptors.softBodies.map(\.entity))
        frame.results.softBodyStates = frame.results.softBodyStates.filter {
            activeSoftBodyEntities.contains($0.key)
        }
        recordPhysicsCommands(in: world, into: &frame)
        frame.jobs.record(bodyCollection.report, for: .fixedPhysicsPrepare)
        frame.jobs.record(constraintCollection.report, for: .fixedPhysicsPrepare)
        frame.metrics.bodyCount = frame.descriptors.bodies.count
        frame.metrics.softBodyCount = frame.descriptors.softBodies.count
        frame.metrics.constraintCount = frame.descriptors.constraints.count

        let syncEventDiff = diffPhysicsSyncEvents(
            bodies: frame.descriptors.bodies,
            constraints: frame.descriptors.constraints,
            vehicles: frame.descriptors.vehicles,
            softBodies: frame.descriptors.softBodies
        )
        frame.results.syncEvents = syncEventDiff.events
        frame.jobs.record(syncEventDiff.report, for: .fixedPhysicsPrepare)

        let prepareContext = PhysicsPrepareContext(
            settings: frame.physicsSettings,
            deltaTimeSeconds: deltaTimeSeconds,
            activeBodies: frame.descriptors.bodies,
            activeConstraints: frame.descriptors.constraints,
            syncEvents: frame.results.syncEvents,
            activeCharacters: frame.descriptors.characters,
            activeVehicles: frame.descriptors.vehicles,
            activeSoftBodies: frame.descriptors.softBodies
        )
        let prepareStarted = DispatchTime.now().uptimeNanoseconds
        let prepareResult = physicsBackend.prepare(context: prepareContext)
        frame.metrics.synchronizationNanoseconds += DispatchTime.now().uptimeNanoseconds - prepareStarted
        frame.metrics.synchronizedBodyCount += prepareResult.synchronizedBodies
        frame.metrics.synchronizedSoftBodyCount += prepareResult.synchronizedSoftBodies
        frame.metrics.synchronizedConstraintCount += prepareResult.synchronizedConstraints
        frame.metrics.error = prepareResult.error
        if prepareResult.error == nil {
            replacePhysicsSyncCache(
                bodies: frame.descriptors.bodies,
                constraints: frame.descriptors.constraints,
                vehicles: frame.descriptors.vehicles,
                softBodies: frame.descriptors.softBodies
            )
        } else {
            physicsSyncCache = PhysicsSyncCache()
        }
        if usesSharedJoltBackend {
            physicsQueryScene.adoptSynchronizedWorld(
                world,
                bodyCount: frame.descriptors.bodies.count,
                constraintCount: frame.descriptors.constraints.count
            )
        }
    }

    /// Clears every physics-derived resource when simulation is switched off, so the
    /// world keeps reporting empty frames instead of stale simulation results.
    mutating func resetDisabledPhysicsResources(world: inout RuntimeWorld) {
        if !usesSharedJoltBackend {
            physicsBackend.reset()
        }
        physicsSyncCache = PhysicsSyncCache()
        physicsClock = PhysicsStepClockResource()
        physicsFrameState = PhysicsFrameStateResource(backendIdentifier: physicsBackend.identifier)
        physicsContactFrame = .empty
        physicsDebugFrame = .empty
        physicsEventFrame = .empty
        characterStateFrame = .empty
        vehicleStateFrame = .empty
        softBodyStateFrame = .empty
        world.setDerivedResource(physicsClock)
        world.setDerivedResource(physicsFrameState)
        world.setDerivedResource(physicsContactFrame)
        world.setDerivedResource(physicsDebugFrame)
        world.setDerivedResource(physicsEventFrame)
        world.setDerivedResource(characterStateFrame)
        world.setDerivedResource(vehicleStateFrame)
        world.setDerivedResource(softBodyStateFrame)
    }

    func recordPhysicsCommands(
        in world: RuntimeWorld,
        into frame: inout RuntimeFrameContext
    ) {
        guard world.resource(PhysicsCommandRecordingResource.self)?.isRecording == true,
              world.resource(PhysicsCommandReplayControlResource.self)?.isReplaying != true
        else { return }
        frame.recording.bodyCommands = frame.descriptors.bodies.compactMap { descriptor in
            guard let body = descriptor.rigidBody else { return nil }
            let hasCommand = body.accumulatedForce != .zero
                || body.accumulatedTorque != .zero
                || body.accumulatedLinearImpulse != .zero
                || body.accumulatedAngularImpulse != .zero
            guard hasCommand else { return nil }
            return PhysicsRecordedBodyCommand(
                entity: descriptor.entity,
                force: body.accumulatedForce,
                torque: body.accumulatedTorque,
                linearImpulse: body.accumulatedLinearImpulse,
                angularImpulse: body.accumulatedAngularImpulse,
                wake: !body.isSleeping
            )
        }
        frame.recording.characterCommands = (world.resource(CharacterCommandFrameResource.self)?.commands ?? [:])
            .map { PhysicsRecordedCharacterCommand(entity: $0.key, command: $0.value) }
            .sorted { $0.entity.rawValue < $1.entity.rawValue }
        frame.recording.vehicleCommands = (world.resource(VehicleCommandFrameResource.self)?.commands ?? [:])
            .map { PhysicsRecordedVehicleCommand(entity: $0.key, command: $0.value) }
            .sorted { $0.entity.rawValue < $1.entity.rawValue }
        frame.recording.destructionCommands = world.resource(DestructionCommandFrameResource.self)?.commands ?? []
    }

    mutating func stepFixedPhysics(
        world: inout RuntimeWorld,
        into frame: inout RuntimeFrameContext,
        deltaTimeSeconds: Double
    ) {
        guard frame.physicsSettings.simulationMode != .off else { return }
        // A failed synchronization means the native world does not match
        // the descriptors for this frame. Preserve the original native
        // error and never advance a partially synchronized world.
        guard frame.metrics.error == nil else { return }
        physicsClock.accumulatedSeconds += deltaTimeSeconds
        physicsClock.lastStepCount = 0
        physicsClock.lastSteppedSeconds = 0
        physicsClock.lastDroppedStepCount = 0

        let fixedStep = max(frame.physicsSettings.fixedTimeStepSeconds, 0.000_001)
        let maxSubsteps = max(frame.physicsSettings.maxSubstepsPerFrame, 0)
        var substepIndex = 0

        while physicsClock.accumulatedSeconds + 0.000_000_1 >= fixedStep && substepIndex < maxSubsteps {
            let stepStarted = DispatchTime.now().uptimeNanoseconds
            let stepResult = physicsBackend.step(
                context: PhysicsStepContext(
                    settings: frame.physicsSettings,
                    stepDeltaSeconds: fixedStep,
                    stepIndex: substepIndex,
                    activeBodies: frame.descriptors.bodies,
                    activeConstraints: frame.descriptors.constraints,
                    activeCharacters: frame.descriptors.characters,
                    characterCommands: world.resource(CharacterCommandFrameResource.self)?.commands ?? [:],
                    activeVehicles: frame.descriptors.vehicles,
                    vehicleCommands: world.resource(VehicleCommandFrameResource.self)?.commands ?? [:],
                    activeSoftBodies: frame.descriptors.softBodies
                )
            )
            frame.metrics.stepNanoseconds += DispatchTime.now().uptimeNanoseconds - stepStarted
            if let error = stepResult.error {
                frame.metrics.error = error
            }
            physicsClock.accumulatedSeconds -= fixedStep
            physicsClock.simulatedSteps += 1
            physicsClock.lastStepCount += 1
            physicsClock.lastSteppedSeconds += fixedStep
            frame.metrics.stepCount += 1
            frame.metrics.contactCount += stepResult.contactCount
            frame.results.contactEvents.append(contentsOf: stepResult.contactEvents)
            frame.results.jointBreakEvents.append(contentsOf: stepResult.jointBreakEvents)
            for event in stepResult.jointBreakEvents {
                _ = world.updateComponent(PhysicsJoint.self, for: event.jointEntity) {
                    $0.isEnabled = false
                }
            }
            frame.results.writebacks = mergeWritebacks(
                existing: frame.results.writebacks,
                incoming: stepResult.writebacks
            )
            for state in stepResult.characterStates {
                frame.results.characterStates[state.entity] = state
            }
            for state in stepResult.vehicleStates {
                frame.results.vehicleStates[state.entity] = state
            }
            for state in stepResult.softBodyStates {
                frame.results.softBodyStates[state.entity] = state
            }
            substepIndex += 1
        }
        if substepIndex >= maxSubsteps,
           physicsClock.accumulatedSeconds + 0.000_000_1 >= fixedStep {
            let dropped = Int(physicsClock.accumulatedSeconds / fixedStep)
            physicsClock.accumulatedSeconds.formTruncatingRemainder(dividingBy: fixedStep)
            physicsClock.droppedSteps += dropped
            physicsClock.lastDroppedStepCount = dropped
        }
    }

    mutating func writeBackPhysics(
        world: inout RuntimeWorld,
        into frame: inout RuntimeFrameContext,
        deltaTimeSeconds: Double
    ) {
        guard frame.physicsSettings.simulationMode != .off else { return }
        for writeback in frame.results.writebacks {
            if world.applyPhysicsWriteback(writeback) {
                frame.metrics.writebackCount += 1
            }
        }
        for state in frame.results.characterStates.values.sorted(by: { $0.entity.rawValue < $1.entity.rawValue }) {
            guard var transform = world.worldTransform(for: state.entity) else { continue }
            transform.matrix.columns.3 = SIMD4<Float>(state.position, 1)
            _ = world.applyPhysicsWriteback(
                PhysicsBodyWriteback(entity: state.entity, worldTransform: transform)
            )
        }
        if frame.metrics.stepCount > 0 {
            _ = world.clearPhysicsAccumulators(for: frame.descriptors.bodies.map(\ .entity))
        }
        if frame.metrics.writebackCount > 0 {
            let report = world.propagateTransforms(using: jobSystem)
            frame.jobs.record(report, for: .physicsWriteback)
        }
        if frame.metrics.stepCount > 0 {
            refreshPhysicsSyncCacheAfterWriteback(in: world, activeBodies: frame.descriptors.bodies)
        }

        physicsFrameState = PhysicsFrameStateResource(
            backendIdentifier: physicsBackend.identifier,
            bodyCount: frame.metrics.bodyCount,
            softBodyCount: frame.metrics.softBodyCount,
            softBodyVertexCount: frame.results.softBodyStates.values.reduce(0) {
                $0 + $1.positions.count
            },
            constraintCount: frame.metrics.constraintCount,
            contactCount: frame.metrics.contactCount,
            writebackCount: frame.metrics.writebackCount,
            simulatedSteps: frame.metrics.stepCount,
            simulatedSeconds: physicsClock.lastSteppedSeconds,
            synchronizedBodyCount: frame.metrics.synchronizedBodyCount,
            synchronizedSoftBodyCount: frame.metrics.synchronizedSoftBodyCount,
            synchronizedConstraintCount: frame.metrics.synchronizedConstraintCount,
            activeBodyCount: frame.results.writebacks.filter { $0.isSleeping == false }.count,
            activeSoftBodyCount: frame.results.softBodyStates.values.filter {
                !$0.isSleeping
            }.count,
            droppedStepCount: physicsClock.lastDroppedStepCount,
            synchronizationNanoseconds: frame.metrics.synchronizationNanoseconds,
            stepNanoseconds: frame.metrics.stepNanoseconds,
            lastError: frame.metrics.error
        )
        physicsContactFrame = PhysicsContactFrameResource(events: frame.results.contactEvents)
        characterStateFrame = CharacterStateFrameResource(states: frame.results.characterStates)
        vehicleStateFrame = VehicleStateFrameResource(states: frame.results.vehicleStates)
        softBodyStateFrame = SoftBodyStateFrameResource(states: frame.results.softBodyStates)
        world.setDerivedResource(physicsClock)
        world.setDerivedResource(physicsFrameState)
        world.setDerivedResource(characterStateFrame)
        world.setDerivedResource(vehicleStateFrame)
        world.setDerivedResource(softBodyStateFrame)
        let stateHashFrame = PhysicsStateHashFrameResource(
            simulatedStep: physicsClock.simulatedSteps,
            hash: physicsStateHash(in: world)
        )
        world.setDerivedResource(stateHashFrame)
        appendPhysicsCommandFrame(
            world: &world,
            frame: frame,
            deltaTimeSeconds: deltaTimeSeconds,
            stateHashFrame: stateHashFrame
        )
        world.setDerivedResource(physicsContactFrame)
        if usesSharedJoltBackend {
            physicsQueryScene.adoptSynchronizedWorld(
                world,
                bodyCount: frame.descriptors.bodies.count,
                constraintCount: frame.descriptors.constraints.count
            )
        }
    }

    func appendPhysicsCommandFrame(
        world: inout RuntimeWorld,
        frame: RuntimeFrameContext,
        deltaTimeSeconds: Double,
        stateHashFrame: PhysicsStateHashFrameResource
    ) {
        guard var recording = world.resource(PhysicsCommandRecordingResource.self),
              recording.isRecording,
              world.resource(PhysicsCommandReplayControlResource.self)?.isReplaying != true
        else { return }
        let steppedThisFrame = frame.metrics.stepCount > 0
        if recording.frames.count < recording.maxFrames {
            recording.frames.append(PhysicsCommandFrame(
                deltaTimeSeconds: deltaTimeSeconds,
                settings: frame.physicsSettings,
                bodyCommands: steppedThisFrame ? frame.recording.bodyCommands : [],
                characterCommands: steppedThisFrame ? frame.recording.characterCommands : [],
                vehicleCommands: steppedThisFrame ? frame.recording.vehicleCommands : [],
                destructionCommands: frame.recording.destructionCommands,
                expectedSimulatedStep: stateHashFrame.simulatedStep,
                expectedStateHash: stateHashFrame.hash
            ))
        }
        if recording.frames.count >= recording.maxFrames {
            recording.isRecording = false
        }
        world.setDerivedResource(recording)
    }

    mutating func detectTriggers(
        world: inout RuntimeWorld,
        into frame: inout RuntimeFrameContext
    ) {
        if frame.physicsSettings.simulationMode == .off {
            // Edit/query-only worlds do not step Jolt and therefore cannot
            // receive contact callbacks. Preserve trigger previews through
            // the query scene; play mode exclusively uses the listener path.
            let triggerBackend = physicsQueryScene.synchronize(in: world)
            let bodyCount = physicsQueryScene.stats.bodyCount
            let triggerFrame = triggerBackend.detectTriggerFrame(
                maxEventCount: bodyCount * max(1, bodyCount) * 3
            )
            physicsEventFrame = PhysicsEventFrameResource(
                triggers: triggerFrame.enters + triggerFrame.active + triggerFrame.exits
            )
            world.setDerivedResource(triggerFrame)
            world.setDerivedResource(physicsEventFrame)
            return
        }
        let triggers = Dictionary(uniqueKeysWithValues: frame.descriptors.bodies.compactMap { body in
            body.collider.map { (body.entity, $0.isTrigger) }
        })
        var contactEvents: [PhysicsContactEvent] = []
        var triggerEvents: [TriggerEvent] = []
        for event in frame.results.contactEvents {
            let aIsTrigger = triggers[event.entityA] == true
            let bIsTrigger = triggers[event.entityB] == true
            guard aIsTrigger || bIsTrigger else {
                contactEvents.append(event)
                continue
            }
            let trigger: EntityID
            let other: EntityID
            if aIsTrigger && !bIsTrigger {
                trigger = event.entityA; other = event.entityB
            } else if bIsTrigger && !aIsTrigger {
                trigger = event.entityB; other = event.entityA
            } else if event.entityA.rawValue <= event.entityB.rawValue {
                trigger = event.entityA; other = event.entityB
            } else {
                trigger = event.entityB; other = event.entityA
            }
            let kind: TriggerEventKind
            switch event.kind {
            case .began: kind = .enter
            case .stayed: kind = .active
            case .ended: kind = .exit
            }
            triggerEvents.append(TriggerEvent(triggerEntity: trigger, otherEntity: other, kind: kind))
        }
        contactEvents.sort {
            ($0.entityA.rawValue, $0.entityB.rawValue, $0.subShapeIDA, $0.subShapeIDB)
                < ($1.entityA.rawValue, $1.entityB.rawValue, $1.subShapeIDA, $1.subShapeIDB)
        }
        triggerEvents.sort {
            ($0.triggerEntity.rawValue, $0.otherEntity.rawValue, $0.kind.rawValue)
                < ($1.triggerEntity.rawValue, $1.otherEntity.rawValue, $1.kind.rawValue)
        }
        let triggerFrame = TriggerFrameResource(
            enters: triggerEvents.filter { $0.kind == .enter },
            exits: triggerEvents.filter { $0.kind == .exit },
            active: triggerEvents.filter { $0.kind != .exit }
        )
        physicsContactFrame = PhysicsContactFrameResource(events: contactEvents)
        physicsEventFrame = PhysicsEventFrameResource(
            contacts: contactEvents,
            triggers: triggerEvents,
            jointBreaks: frame.results.jointBreakEvents
        )
        world.setDerivedResource(triggerFrame)
        world.setDerivedResource(physicsContactFrame)
        world.setDerivedResource(physicsEventFrame)
        applyDestructionContacts(
            contactEvents,
            in: &world,
            frame: &frame.recording.destructionEvents
        )
    }

    mutating func runPostPhysicsScripts(
        world: inout RuntimeWorld,
        commands: inout RuntimeCommandBuffer,
        into frame: inout RuntimeFrameContext,
        deltaTimeSeconds: Double
    ) {
        if let scriptDriver {
            withUnsafeMutablePointer(to: &world) { worldPointer in
                withUnsafeMutablePointer(to: &commands) { commandPointer in
                    var scriptContext = RuntimeScriptPhaseContext(
                        world: worldPointer,
                        commands: commandPointer,
                        deltaTimeSeconds: deltaTimeSeconds,
                        physicsQueryScene: physicsQueryScene
                    )
                    scriptDriver.runPostPhysics(context: &scriptContext)
                }
            }
        }
        writeRagdollPhysicsToAnimation(in: &world)
        if world.hierarchyNeedsPropagation() {
            let report = world.propagateTransforms(using: jobSystem)
            frame.jobs.record(report, for: .postPhysicsScripts)
        }
        advanceParticleEmitters(world: &world, deltaTimeSeconds: deltaTimeSeconds)
    }

    func advanceParticleEmitters(world: inout RuntimeWorld, deltaTimeSeconds: Double) {
        guard deltaTimeSeconds > 0 else {
            world.setDerivedResource(ParticleFrameStatsResource.empty)
            world.setDerivedResource(ParticleScalabilityStateResource.default)
            return
        }
        let particleOptions = particleAdvanceOptions(in: &world)
        let particleEntities = world.entities(with: ParticleEmitter.self)
        let worldTransforms = world.worldTransformSnapshot(matching: particleEntities)
        var particleStats: [ParticleEmitterFrameStats] = []
        var particleStatsByEntity: [UInt64: ParticleEmitterFrameStats] = [:]
        particleStats.reserveCapacity(particleEntities.count)
        particleStatsByEntity.reserveCapacity(particleEntities.count)
        world.updateComponents(ParticleEmitter.self) { entity, emitter in
            emitter.advance(deltaTime: deltaTimeSeconds,
                            worldTransform: worldTransforms[entity]?.matrix,
                            options: particleOptions)
            particleStats.append(emitter.lastFrameStats)
            particleStatsByEntity[entity.rawValue] = emitter.lastFrameStats
        }
        world.setDerivedResource(
            ParticleFrameStatsResource(simulatedDeltaTime: Float(deltaTimeSeconds),
                                       emitterStats: particleStats,
                                       emitterStatsByEntity: particleStatsByEntity)
        )
    }

    mutating func updateSpatialIndex(
        world: inout RuntimeWorld,
        into frame: inout RuntimeFrameContext
    ) {
        let spatialIndexBuild = buildSpatialIndexResource(in: world, using: jobSystem)
        world.setDerivedResource(spatialIndexBuild.resource)
        physicsDebugFrame = buildPhysicsDebugFrame(
            in: world,
            spatialIndex: spatialIndexBuild.resource,
            contacts: frame.results.contactEvents
        )
        world.setDerivedResource(physicsDebugFrame)
        frame.jobs.record(spatialIndexBuild.report, for: .spatialIndexUpdate)
    }

    mutating func replacePhysicsSyncCache(
        bodies: [PhysicsBodyDescriptor],
        constraints: [PhysicsConstraintDescriptor],
        vehicles: [PhysicsVehicleDescriptor],
        softBodies: [PhysicsSoftBodyDescriptor]
    ) {
        physicsSyncCache.bodies = Dictionary(uniqueKeysWithValues: bodies.map { ($0.entity, $0) })
        physicsSyncCache.constraints = Dictionary(uniqueKeysWithValues: constraints.map { ($0.entity, $0) })
        physicsSyncCache.vehicles = Dictionary(uniqueKeysWithValues: vehicles.map { ($0.entity, $0) })
        physicsSyncCache.softBodies = Dictionary(uniqueKeysWithValues: softBodies.map { ($0.entity, $0) })
    }

    mutating func refreshPhysicsSyncCacheAfterWriteback(
        in world: RuntimeWorld,
        activeBodies: [PhysicsBodyDescriptor]
    ) {
        for original in activeBodies {
            guard var cached = physicsSyncCache.bodies[original.entity],
                  let localTransform = world.localTransform(for: original.entity),
                  let worldTransform = world.worldTransform(for: original.entity)
            else { continue }
            cached.localTransform = localTransform
            cached.worldTransform = worldTransform
            cached.rigidBody = world.component(RigidBody.self, for: original.entity)
            cached.collider = world.component(Collider.self, for: original.entity)
            physicsSyncCache.bodies[original.entity] = cached
        }
    }
}

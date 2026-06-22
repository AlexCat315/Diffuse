import Foundation
import EngineKernel
import SIMDCompat

public enum RuntimeSystemPhase: String, CaseIterable, Sendable {
    case commandApply
    case hierarchyPropagate
    case fixedPhysicsPrepare
    case fixedPhysicsStep
    case physicsWriteback
    case animationAndScripts
    case spatialIndexUpdate
    case triggerDetection
    case renderExtract
}

public enum RuntimeCommand: Sendable {
    case createEntity
    case destroyEntity(EntityID)
    case setParent(parent: EntityID?, child: EntityID)
    case setLocalTransform(entity: EntityID, transform: LocalTransform)
}

public struct RuntimeCommandBuffer: Sendable {
    private var commands: [RuntimeCommand] = []

    public init() {}

    public var count: Int {
        commands.count
    }

    public var isEmpty: Bool {
        commands.isEmpty
    }

    public mutating func enqueue(_ command: RuntimeCommand) {
        commands.append(command)
    }

    public mutating func createEntity() {
        enqueue(.createEntity)
    }

    public mutating func destroyEntity(_ entity: EntityID) {
        enqueue(.destroyEntity(entity))
    }

    public mutating func setParent(_ parent: EntityID?, for child: EntityID) {
        enqueue(.setParent(parent: parent, child: child))
    }

    public mutating func setLocalTransform(_ transform: LocalTransform, for entity: EntityID) {
        enqueue(.setLocalTransform(entity: entity, transform: transform))
    }

    mutating func drain() -> [RuntimeCommand] {
        let drained = commands
        commands.removeAll(keepingCapacity: true)
        return drained
    }
}

public struct RuntimeScheduleReport: Sendable {
    public var phases: [RuntimeSystemPhase]
    public var appliedCommandCount: Int
    public var createdEntities: [EntityID]
    public var destroyedEntities: [EntityID]
    public var physicsStepCount: Int
    public var physicsWritebackCount: Int
    public var physicsBodyCount: Int
    public var physicsConstraintCount: Int
    public var physicsContactCount: Int
    public var physicsBackendIdentifier: String
    public var scheduledJobCount: Int
    public var jobWorkerCount: Int
    public var parallelPhases: [RuntimeSystemPhase]
    public var phaseJobCounts: [RuntimeSystemPhase: Int]
    public var revision: UInt64

    public init(
        phases: [RuntimeSystemPhase] = [],
        appliedCommandCount: Int = 0,
        createdEntities: [EntityID] = [],
        destroyedEntities: [EntityID] = [],
        physicsStepCount: Int = 0,
        physicsWritebackCount: Int = 0,
        physicsBodyCount: Int = 0,
        physicsConstraintCount: Int = 0,
        physicsContactCount: Int = 0,
        physicsBackendIdentifier: String = "none",
        scheduledJobCount: Int = 0,
        jobWorkerCount: Int = 1,
        parallelPhases: [RuntimeSystemPhase] = [],
        phaseJobCounts: [RuntimeSystemPhase: Int] = [:],
        revision: UInt64 = 0
    ) {
        self.phases = phases
        self.appliedCommandCount = appliedCommandCount
        self.createdEntities = createdEntities
        self.destroyedEntities = destroyedEntities
        self.physicsStepCount = physicsStepCount
        self.physicsWritebackCount = physicsWritebackCount
        self.physicsBodyCount = physicsBodyCount
        self.physicsConstraintCount = physicsConstraintCount
        self.physicsContactCount = physicsContactCount
        self.physicsBackendIdentifier = physicsBackendIdentifier
        self.scheduledJobCount = scheduledJobCount
        self.jobWorkerCount = jobWorkerCount
        self.parallelPhases = parallelPhases
        self.phaseJobCounts = phaseJobCounts
        self.revision = revision
    }

    public func jobCount(for phase: RuntimeSystemPhase) -> Int {
        phaseJobCounts[phase] ?? 0
    }
}

public struct RuntimeWorldSchedule {
    private struct ExtractedRenderInstance {
        var entity: EntityID
        var instance: RenderInstance
    }

    private struct ExtractedRenderLight {
        var entity: EntityID
        var light: RenderLight
    }

    private struct PhysicsSyncCache {
        var bodies: [EntityID: PhysicsBodyDescriptor] = [:]
        var constraints: [EntityID: PhysicsConstraintDescriptor] = [:]
    }

    private struct RuntimePhysicsReadView {
        var entities: [EntityID]
        var localTransforms: [EntityID: LocalTransform]
        var worldTransforms: [EntityID: WorldTransform]
        var rigidBodies: [EntityID: RigidBody]
        var colliders: [EntityID: Collider]
        var constraints: [EntityID: Constraint]
        var meshGeometries: [EntityID: MeshColliderGeometry]
    }

    private struct RuntimeRenderReadView {
        var entities: [EntityID]
        var worldTransforms: [EntityID: WorldTransform]
        var cameras: [EntityID: CameraComponent]
        var renderMeshes: [EntityID: RenderMeshComponent]
        var renderMaterials: [EntityID: RenderMaterialComponent]
        var lights: [EntityID: LightComponent]
        var assetReferences: [EntityID: AssetReferenceComponent]
    }

    private var physicsBackend: any PhysicsBackend = NullPhysicsBackend()
    private var explicitPhysicsBackend: (any PhysicsBackend)?
    private var scriptDriver: (any RuntimeScriptDriver)?
    private var physicsClock = PhysicsStepClockResource()
    private var physicsFrameState = PhysicsFrameStateResource()
    private var physicsSyncCache = PhysicsSyncCache()
    private var resolvedPhysicsBackendKind: PhysicsBackendKind = .none
    private var jobSystem = JobSystem.shared
    private var triggerDetector = TriggerDetector()

    public init() {}

    public mutating func setPhysicsBackend(_ backend: any PhysicsBackend) {
        explicitPhysicsBackend = backend
        physicsBackend = backend
        resolvedPhysicsBackendKind = .none
        physicsFrameState.backendIdentifier = backend.identifier
    }

    public mutating func clearPhysicsBackendOverride() {
        explicitPhysicsBackend = nil
        resolvedPhysicsBackendKind = .none
        physicsBackend = NullPhysicsBackend()
        physicsFrameState.backendIdentifier = physicsBackend.identifier
    }

    public mutating func setScriptDriver(_ driver: any RuntimeScriptDriver) {
        scriptDriver?.reset()
        scriptDriver = driver
    }

    public mutating func clearScriptDriver() {
        scriptDriver?.reset()
        scriptDriver = nil
    }

    public mutating func setJobSystem(_ jobSystem: JobSystem) {
        self.jobSystem = jobSystem
    }

    public var currentPhysicsBackendIdentifier: String {
        physicsBackend.identifier
    }

    public var currentPhysicsClock: PhysicsStepClockResource {
        physicsClock
    }

    public var currentPhysicsFrameState: PhysicsFrameStateResource {
        physicsFrameState
    }

    public mutating func run(
        world: inout RuntimeWorld,
        commands: inout RuntimeCommandBuffer,
        deltaTimeSeconds: Double
    ) -> RuntimeScheduleReport {
        let drainedCommands = commands.drain()
        var createdEntities: [EntityID] = []
        var destroyedEntities: [EntityID] = []
        let physicsSettings = world.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
        var physicsStepCount = 0
        var physicsWritebackCount = 0
        var physicsBodyCount = 0
        var physicsConstraintCount = 0
        var physicsContactCount = 0
        var scheduledJobCount = 0
        var parallelPhases = Set<RuntimeSystemPhase>()
        var phaseJobCounts: [RuntimeSystemPhase: Int] = [:]

        func recordJobReport(_ report: JobDispatchReport, for phase: RuntimeSystemPhase) {
            guard report.jobCount > 0 else { return }
            scheduledJobCount += report.jobCount
            phaseJobCounts[phase, default: 0] += report.jobCount
            if report.executedInParallel {
                parallelPhases.insert(phase)
            }
        }

        var activeBodies: [PhysicsBodyDescriptor] = []
        var activeConstraints: [PhysicsConstraintDescriptor] = []
        var syncEvents: [PhysicsSyncEvent] = []
        var pendingWritebacks: [PhysicsBodyWriteback] = []

        ensureConfiguredPhysicsBackend(kind: physicsSettings.backendKind)

        for phase in RuntimeSystemPhase.allCases {
            switch phase {
            case .commandApply:
                for command in drainedCommands {
                    switch command {
                    case .createEntity:
                        createdEntities.append(world.createEntity())
                    case let .destroyEntity(entity):
                        if world.destroyEntity(entity) {
                            destroyedEntities.append(entity)
                        }
                    case let .setParent(parent, child):
                        _ = world.setParent(parent, for: child)
                    case let .setLocalTransform(entity, transform):
                        _ = world.setLocalTransform(transform, for: entity)
                    }
                }
            case .hierarchyPropagate:
                let report = world.propagateTransforms(using: jobSystem)
                recordJobReport(report, for: .hierarchyPropagate)
            case .fixedPhysicsPrepare:
                guard physicsSettings.simulationMode != .off else {
                    physicsBackend.reset()
                    physicsSyncCache = PhysicsSyncCache()
                    physicsClock = PhysicsStepClockResource()
                    physicsFrameState = PhysicsFrameStateResource(backendIdentifier: physicsBackend.identifier)
                    world.setDerivedResource(physicsClock)
                    world.setDerivedResource(physicsFrameState)
                    continue
                }

                let physicsReadView = buildPhysicsReadView(in: world)
                let bodyCollection = collectPhysicsBodies(from: physicsReadView)
                activeBodies = bodyCollection.bodies
                let constraintCollection = collectPhysicsConstraints(from: physicsReadView)
                activeConstraints = constraintCollection.constraints
                recordJobReport(bodyCollection.report, for: .fixedPhysicsPrepare)
                recordJobReport(constraintCollection.report, for: .fixedPhysicsPrepare)
                physicsBodyCount = activeBodies.count
                physicsConstraintCount = activeConstraints.count
                let syncEventDiff = diffPhysicsSyncEvents(
                    bodies: activeBodies,
                    constraints: activeConstraints
                )
                syncEvents = syncEventDiff.events
                recordJobReport(syncEventDiff.report, for: .fixedPhysicsPrepare)
                let prepareContext = PhysicsPrepareContext(
                    settings: physicsSettings,
                    deltaTimeSeconds: deltaTimeSeconds,
                    activeBodies: activeBodies,
                    activeConstraints: activeConstraints,
                    syncEvents: syncEvents
                )
                _ = physicsBackend.prepare(context: prepareContext)
                replacePhysicsSyncCache(bodies: activeBodies, constraints: activeConstraints)
            case .fixedPhysicsStep:
                guard physicsSettings.simulationMode != .off else { continue }
                physicsClock.accumulatedSeconds += deltaTimeSeconds
                physicsClock.lastStepCount = 0
                physicsClock.lastSteppedSeconds = 0

                let fixedStep = max(physicsSettings.fixedTimeStepSeconds, 0.000_001)
                let maxSubsteps = max(physicsSettings.maxSubstepsPerFrame, 0)
                var substepIndex = 0

                while physicsClock.accumulatedSeconds + 0.000_000_1 >= fixedStep && substepIndex < maxSubsteps {
                    let stepResult = physicsBackend.step(
                        context: PhysicsStepContext(
                            settings: physicsSettings,
                            stepDeltaSeconds: fixedStep,
                            stepIndex: substepIndex,
                            activeBodies: activeBodies,
                            activeConstraints: activeConstraints
                        )
                    )
                    physicsClock.accumulatedSeconds -= fixedStep
                    physicsClock.simulatedSteps += 1
                    physicsClock.lastStepCount += 1
                    physicsClock.lastSteppedSeconds += fixedStep
                    physicsStepCount += 1
                    physicsContactCount += stepResult.contactCount
                    pendingWritebacks = mergeWritebacks(existing: pendingWritebacks, incoming: stepResult.writebacks)
                    substepIndex += 1
                }
            case .physicsWriteback:
                guard physicsSettings.simulationMode != .off else { continue }
                for writeback in pendingWritebacks {
                    if world.applyPhysicsWriteback(writeback) {
                        physicsWritebackCount += 1
                    }
                }
                if physicsStepCount > 0 {
                    _ = world.clearPhysicsAccumulators(for: activeBodies.map(\ .entity))
                }
                if physicsWritebackCount > 0 {
                    let report = world.propagateTransforms(using: jobSystem)
                    recordJobReport(report, for: .physicsWriteback)
                }
                physicsFrameState = PhysicsFrameStateResource(
                    backendIdentifier: physicsBackend.identifier,
                    bodyCount: physicsBodyCount,
                    constraintCount: physicsConstraintCount,
                    contactCount: physicsContactCount,
                    writebackCount: physicsWritebackCount,
                    simulatedSteps: physicsStepCount,
                    simulatedSeconds: physicsClock.lastSteppedSeconds
                )
                world.setDerivedResource(physicsClock)
                world.setDerivedResource(physicsFrameState)
            case .animationAndScripts:
                if let scriptDriver {
                    withUnsafeMutablePointer(to: &world) { worldPointer in
                        withUnsafeMutablePointer(to: &commands) { commandPointer in
                            var scriptContext = RuntimeScriptPhaseContext(
                                world: worldPointer,
                                commands: commandPointer,
                                deltaTimeSeconds: deltaTimeSeconds
                            )
                            scriptDriver.run(context: &scriptContext)
                        }
                    }
                }
                if world.hierarchyNeedsPropagation() {
                    let report = world.propagateTransforms(using: jobSystem)
                    recordJobReport(report, for: .animationAndScripts)
                }
                if deltaTimeSeconds > 0 {
                    let particleOptions = particleAdvanceOptions(in: &world)
                    let particleEntities = world.entities(with: ParticleEmitter.self)
                    let worldTransforms = world.worldTransformSnapshot(matching: particleEntities)
                    var particleStats: [ParticleEmitterFrameStats] = []
                    particleStats.reserveCapacity(particleEntities.count)
                    world.updateComponents(ParticleEmitter.self) { entity, emitter in
                        emitter.advance(deltaTime: deltaTimeSeconds,
                                        worldTransform: worldTransforms[entity]?.matrix,
                                        options: particleOptions)
                        particleStats.append(emitter.lastFrameStats)
                    }
                    world.setDerivedResource(
                        ParticleFrameStatsResource(simulatedDeltaTime: Float(deltaTimeSeconds),
                                                   emitterStats: particleStats)
                    )
                } else {
                    world.setDerivedResource(ParticleFrameStatsResource.empty)
                    world.setDerivedResource(ParticleScalabilityStateResource.default)
                }
            case .spatialIndexUpdate:
                let spatialIndexBuild = buildSpatialIndexResource(in: world, using: jobSystem)
                world.setDerivedResource(spatialIndexBuild.resource)
                recordJobReport(spatialIndexBuild.report, for: .spatialIndexUpdate)
            case .triggerDetection:
                if let index = world.resource(SpatialIndexResource.self) {
                    let triggerFrame = triggerDetector.detect(in: index)
                    world.setDerivedResource(triggerFrame)
                } else {
                    world.setDerivedResource(TriggerFrameResource())
                }
            case .renderExtract:
                let renderExtraction = extractRenderScene(in: world)
                world.setDerivedResource(renderExtraction.resource)
                recordJobReport(renderExtraction.report, for: .renderExtract)
                break
            }
        }

        world.advanceRevision()

        return RuntimeScheduleReport(
            phases: RuntimeSystemPhase.allCases,
            appliedCommandCount: drainedCommands.count,
            createdEntities: createdEntities,
            destroyedEntities: destroyedEntities,
            physicsStepCount: physicsStepCount,
            physicsWritebackCount: physicsWritebackCount,
            physicsBodyCount: physicsBodyCount,
            physicsConstraintCount: physicsConstraintCount,
            physicsContactCount: physicsContactCount,
            physicsBackendIdentifier: physicsBackend.identifier,
            scheduledJobCount: scheduledJobCount,
            jobWorkerCount: jobSystem.workerCount,
            parallelPhases: RuntimeSystemPhase.allCases.filter { parallelPhases.contains($0) },
            phaseJobCounts: phaseJobCounts,
            revision: world.revision
        )
    }

    private mutating func replacePhysicsSyncCache(
        bodies: [PhysicsBodyDescriptor],
        constraints: [PhysicsConstraintDescriptor]
    ) {
        physicsSyncCache.bodies = Dictionary(uniqueKeysWithValues: bodies.map { ($0.entity, $0) })
        physicsSyncCache.constraints = Dictionary(uniqueKeysWithValues: constraints.map { ($0.entity, $0) })
    }

    private func collectPhysicsBodies(
        from view: RuntimePhysicsReadView
    ) -> (bodies: [PhysicsBodyDescriptor], report: JobDispatchReport) {
        let result = jobSystem.parallelCompactMap(items: view.entities) { entity -> PhysicsBodyDescriptor? in
            let rigidBody = view.rigidBodies[entity]
            let collider = view.colliders[entity]
            guard rigidBody != nil || collider != nil,
                  let localTransform = view.localTransforms[entity],
                  let worldTransform = view.worldTransforms[entity]
            else {
                return nil
            }
            return PhysicsBodyDescriptor(
                entity: entity,
                localTransform: localTransform,
                worldTransform: worldTransform,
                rigidBody: rigidBody,
                collider: collider,
                meshGeometry: view.meshGeometries[entity]
            )
        }
        return (result.0, result.1)
    }

    private func collectPhysicsConstraints(
        from view: RuntimePhysicsReadView
    ) -> (constraints: [PhysicsConstraintDescriptor], report: JobDispatchReport) {
        let result = jobSystem.parallelCompactMap(items: view.entities) { entity -> PhysicsConstraintDescriptor? in
            guard let constraint = view.constraints[entity],
                  let worldTransform = view.worldTransforms[entity]
            else {
                return nil
            }
            return PhysicsConstraintDescriptor(
                entity: entity,
                worldTransform: worldTransform,
                constraint: constraint
            )
        }
        return (result.0, result.1)
    }

    private func diffPhysicsSyncEvents(
        bodies: [PhysicsBodyDescriptor],
        constraints: [PhysicsConstraintDescriptor]
    ) -> (events: [PhysicsSyncEvent], report: JobDispatchReport) {
        let previousBodies = physicsSyncCache.bodies
        let previousConstraints = physicsSyncCache.constraints
        let bodyMap = Dictionary(uniqueKeysWithValues: bodies.map { ($0.entity, $0) })
        let constraintMap = Dictionary(uniqueKeysWithValues: constraints.map { ($0.entity, $0) })

        let bodyUpserts = jobSystem.parallelCompactMap(items: bodies) { descriptor -> PhysicsSyncEvent? in
            previousBodies[descriptor.entity] == descriptor ? nil : .bodyUpsert(descriptor)
        }
        let bodyRemovals = jobSystem.parallelCompactMap(items: Array(previousBodies.keys)) { entity -> PhysicsSyncEvent? in
            bodyMap[entity] == nil ? .bodyRemove(entity) : nil
        }
        let constraintUpserts = jobSystem.parallelCompactMap(items: constraints) { descriptor -> PhysicsSyncEvent? in
            previousConstraints[descriptor.entity] == descriptor ? nil : .constraintUpsert(descriptor)
        }
        let constraintRemovals = jobSystem.parallelCompactMap(items: Array(previousConstraints.keys)) { entity -> PhysicsSyncEvent? in
            constraintMap[entity] == nil ? .constraintRemove(entity) : nil
        }

        let reports = [bodyUpserts.1, bodyRemovals.1, constraintUpserts.1, constraintRemovals.1]
        return (
            bodyUpserts.0 + bodyRemovals.0 + constraintUpserts.0 + constraintRemovals.0,
            mergeDispatchReports(reports)
        )
    }

    private func mergeWritebacks(
        existing: [PhysicsBodyWriteback],
        incoming: [PhysicsBodyWriteback]
    ) -> [PhysicsBodyWriteback] {
        var merged = Dictionary(uniqueKeysWithValues: existing.map { ($0.entity, $0) })
        for writeback in incoming {
            merged[writeback.entity] = writeback
        }
        return Array(merged.values)
    }

    private mutating func ensureConfiguredPhysicsBackend(kind: PhysicsBackendKind) {
        guard explicitPhysicsBackend == nil else { return }
        guard resolvedPhysicsBackendKind != kind else { return }

        physicsBackend.reset()
        switch kind {
        case .none:
            physicsBackend = NullPhysicsBackend()
        case .jolt:
            physicsBackend = JoltPhysicsBackend()
        }
        resolvedPhysicsBackendKind = kind
        physicsFrameState.backendIdentifier = physicsBackend.identifier
    }

    private func particleAdvanceOptions(in world: inout RuntimeWorld) -> ParticleAdvanceOptions {
        let baseOptions = (world.resource(ParticleScalabilityResource.self)
            ?? .default).advanceOptions
        let policy = world.resource(ParticleScalabilityPolicyResource.self) ?? .disabled
        let state = policy.updatedState(
            previousStats: world.resource(ParticleFrameStatsResource.self) ?? .empty,
            previousState: world.resource(ParticleScalabilityStateResource.self) ?? .default
        )
        world.setDerivedResource(state)
        return state.applying(to: baseOptions)
    }

    private func extractRenderScene(
        in world: RuntimeWorld
    ) -> (resource: ExtractedRenderSceneResource, report: JobDispatchReport) {
        let view = buildRenderReadView(in: world)
        let cameraSelection = selectRenderCamera(from: view)
        let instanceCollection = collectRenderInstances(from: view)
        let lightCollection = collectRenderLights(from: view)
        let instances = instanceCollection.instances
        let lights = lightCollection.lights
        let particles = collectRenderParticles(in: world, camera: cameraSelection.camera)
        let particleSimulationBatches = collectParticleSimulationBatches(in: world,
                                                                         camera: cameraSelection.camera)
        return (
            ExtractedRenderSceneResource(
                scene: RenderScene(
                    camera: cameraSelection.camera,
                    instances: instances.map(\.instance),
                    lights: lights.map(\.light),
                    particles: particles,
                    particleSimulationBatches: particleSimulationBatches
                ),
                activeCameraEntity: cameraSelection.entity,
                instanceEntities: instances.map(\.entity),
                lightEntities: lights.map(\.entity),
                sourceRevision: world.revision
            ),
            mergeDispatchReports([cameraSelection.report, instanceCollection.report, lightCollection.report])
        )
    }

    private func collectParticleSimulationBatches(in world: RuntimeWorld,
                                                  camera: RenderCamera)
        -> [RenderParticleSimulationBatch] {
        var result: [RenderParticleSimulationBatch] = []
        for entity in world.entities(with: ParticleEmitter.self) {
            guard let emitter = world.component(ParticleEmitter.self, for: entity),
                  !emitter.particles.isEmpty
            else { continue }
            let plan = emitter.gpuSimulationPlan
            guard plan.usesGPU else { continue }
            let toWorld = world.worldTransform(for: entity)?.matrix ?? matrix_identity_float4x4
            let canRenderOnGPU = canRenderEmitterParticlesOnGPU(emitter)
            let isRenderVisible = canRenderOnGPU
                && isEmitterVisibleToCamera(emitter: emitter,
                                            toWorld: toWorld,
                                            camera: camera)
            let distanceFade = isRenderVisible
                ? renderDistanceFade(emitter: emitter, toWorld: toWorld, cameraEye: camera.eye)
                : 0
            let cameraDistance = emitterCameraDistance(emitter: emitter,
                                                       toWorld: toWorld,
                                                       cameraEye: camera.eye)
            let renderParticleLimit = emitter.effectiveMaxRenderedParticles(
                cameraDistance: cameraDistance,
                liveParticleCount: emitter.particles.count
            )
            let renderOnGPU = canRenderOnGPU && distanceFade > 0 && renderParticleLimit > 0
            let renderAlphaScale = renderOnGPU ? distanceFade : 0
            let frameSpawnCount = min(
                emitter.lastFrameSpawnedParticles.count,
                emitter.lastFrameStats.spawnedParticleCount,
                emitter.particles.count
            )
            let persistedParticleCount = max(0, emitter.particles.count - frameSpawnCount)
            let persistedParticles = Array(emitter.particles.prefix(persistedParticleCount))
            let spawnParticles = Array(emitter.lastFrameSpawnedParticles.suffix(frameSpawnCount))
            result.append(
                RenderParticleSimulationBatch(
                    emitterEntity: entity,
                    plan: plan,
                    particles: persistedParticles,
                    spawnParticles: spawnParticles,
                    gravity: emitter.gravity,
                    noiseStrength: emitter.noiseStrength,
                    noiseScale: emitter.noiseScale,
                    noiseSpeed: emitter.noiseSpeed,
                    noiseSeed: emitter.seed,
                    vectorFieldMode: emitter.vectorFieldMode,
                    vectorFieldDirection: emitter.vectorFieldDirection,
                    vectorFieldStrength: emitter.vectorFieldStrength,
                    vectorFieldScale: emitter.vectorFieldScale,
                    vectorFieldScrollSpeed: emitter.vectorFieldScrollSpeed,
                    forceMode: emitter.forceMode,
                    forceCenter: emitter.forceCenter,
                    forceAxis: emitter.forceAxis,
                    forceRadius: emitter.forceRadius,
                    forceStrength: emitter.forceStrength,
                    forceFalloff: emitter.forceFalloff,
                    collisionMode: emitter.collisionMode,
                    collisionPlaneY: emitter.collisionPlaneY,
                    collisionRestitution: emitter.collisionRestitution,
                    collisionDamping: emitter.collisionDamping,
                    renderOnGPU: renderOnGPU,
                    worldTransform: emitter.simulationSpace == .local ? toWorld : matrix_identity_float4x4,
                    uvRect: SIMD4<Float>(0, 0, 1, 1),
                    textureSheetColumns: emitter.textureSheetColumns,
                    textureSheetRows: emitter.textureSheetRows,
                    textureSheetFrameCount: emitter.textureSheetFrameCount,
                    textureSheetFrameRate: emitter.textureSheetFrameRate,
                    blendMode: emitter.blendMode,
                    texturePath: emitter.texturePath,
                    renderAlignment: emitter.renderAlignment,
                    velocityStretchScale: emitter.velocityStretchScale,
                    velocityStretchMax: emitter.velocityStretchMax,
                    renderParticleLimit: renderParticleLimit,
                    renderAlphaScale: renderAlphaScale,
                    trailLength: emitter.trailLength,
                    trailSegments: emitter.trailSegments,
                    trailEndSizeScale: emitter.trailEndSizeScale,
                    trailEndAlphaScale: emitter.trailEndAlphaScale
                )
            )
        }
        return result
    }

    private func canRenderEmitterParticlesOnGPU(_ emitter: ParticleEmitter) -> Bool {
        guard emitter.gpuSimulationPlan.usesGPU else { return false }
        guard emitter.renderAlignment == .billboard || emitter.renderAlignment == .velocity else { return false }
        guard emitter.textureAssetID == nil || emitter.texturePath != nil else { return false }
        return true
    }

    /// Flattens every live `ParticleEmitter` pool into world-space billboard
    /// particles for the render backend. Local-space particles are transformed
    /// by the entity's world matrix; world-space particles are already stored in
    /// render space. The result is sorted back-to-front for the camera so alpha
    /// blending composites correctly.
    private func collectRenderParticles(
        in world: RuntimeWorld,
        camera: RenderCamera
    ) -> [RenderParticle] {
        var result: [RenderParticle] = []
        for entity in world.entities(with: ParticleEmitter.self) {
            guard let emitter = world.component(ParticleEmitter.self, for: entity),
                  !emitter.particles.isEmpty
            else { continue }
            if canRenderEmitterParticlesOnGPU(emitter) {
                continue
            }
            let toWorld = world.worldTransform(for: entity)?.matrix ?? matrix_identity_float4x4
            if !isEmitterVisibleToCamera(emitter: emitter,
                                         toWorld: toWorld,
                                         camera: camera) {
                continue
            }
            let distanceFade = renderDistanceFade(emitter: emitter,
                                                  toWorld: toWorld,
                                                  cameraEye: camera.eye)
            if distanceFade <= 0 {
                continue
            }
            let cameraDistance = emitterCameraDistance(emitter: emitter,
                                                       toWorld: toWorld,
                                                       cameraEye: camera.eye)
            let sourceParticles = renderSourceParticles(for: emitter,
                                                        cameraDistance: cameraDistance)
            let trailSegments = emitter.trailLength > 0 ? emitter.trailSegments : 0
            result.reserveCapacity(result.count + sourceParticles.count * (1 + trailSegments))
            for particle in sourceParticles {
                let worldPosition: SIMD3<Float>
                let worldVelocity: SIMD3<Float>
                switch emitter.simulationSpace {
                case .local:
                    let transformed = toWorld * SIMD4<Float>(particle.position, 1)
                    if abs(transformed.w) > 0.0001 {
                        worldPosition = SIMD3<Float>(
                            transformed.x / transformed.w,
                            transformed.y / transformed.w,
                            transformed.z / transformed.w
                        )
                    } else {
                        worldPosition = SIMD3<Float>(transformed.x, transformed.y, transformed.z)
                    }
                    worldVelocity = Self.transformDirection(particle.velocity, by: toWorld)
                case .world:
                    worldPosition = particle.position
                    worldVelocity = particle.velocity
                }
                let uvRect = emitter.textureUVRect(for: particle)
                let alignment = renderAlignment(for: emitter, worldVelocity: worldVelocity)
                var color = particle.color
                color.w *= distanceFade
                let base = RenderParticle(
                    position: worldPosition,
                    size: particle.size,
                    rotation: particle.rotation,
                    color: color,
                    uvRect: uvRect,
                    alignmentAxis: alignment.axis,
                    stretch: alignment.stretch,
                    blendMode: emitter.blendMode,
                    texturePath: emitter.texturePath
                )
                result.append(base)
                appendTrailParticles(for: particle,
                                     emitter: emitter,
                                     base: base,
                                     worldVelocity: worldVelocity,
                                     to: &result)
            }
        }
        result.sort {
            simd_length_squared($0.position - camera.eye) > simd_length_squared($1.position - camera.eye)
        }
        return result
    }

    private func renderSourceParticles(
        for emitter: ParticleEmitter,
        cameraDistance: Float
    ) -> ArraySlice<Particle> {
        let budget = emitter.effectiveMaxRenderedParticles(cameraDistance: cameraDistance,
                                                           liveParticleCount: emitter.particles.count)
        guard budget > 0 else {
            return emitter.particles[emitter.particles.endIndex...]
        }
        guard budget < emitter.particles.count else {
            return emitter.particles[...]
        }
        return emitter.particles.suffix(budget)
    }

    private struct CameraBasis {
        var forward: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
    }

    private func isEmitterVisibleToCamera(
        emitter: ParticleEmitter,
        toWorld: simd_float4x4,
        camera: RenderCamera
    ) -> Bool {
        let radius = emitter.effectiveRenderBoundsRadius()
        guard radius > 0 else {
            return true
        }
        let center = Self.transformPoint(emitter.originOffset, by: toWorld)
        let basis = cameraBasis(for: camera)
        let offset = center - camera.eye
        let forwardDistance = simd_dot(offset, basis.forward)

        if forwardDistance + radius < camera.near {
            return false
        }
        if camera.far > camera.near,
           forwardDistance - radius > camera.far {
            return false
        }

        let verticalHalfFov = max(0.001, min(Float.pi * 0.49, camera.fovYRadians * 0.5))
        let verticalHalfExtent = max(0, forwardDistance) * Float(tan(Double(verticalHalfFov))) + radius
        let verticalDistance = abs(simd_dot(offset, basis.up))
        if verticalDistance > verticalHalfExtent {
            return false
        }
        let horizontalHalfExtent = max(0, forwardDistance)
            * Float(tan(Double(verticalHalfFov)))
            * max(0.001, camera.aspectRatio)
            + radius
        let horizontalDistance = abs(simd_dot(offset, basis.right))
        if horizontalDistance > horizontalHalfExtent {
            return false
        }
        return true
    }

    private func cameraBasis(for camera: RenderCamera) -> CameraBasis {
        let rawForward = camera.target - camera.eye
        let forward = normalizedOrDefault(rawForward, SIMD3<Float>(0, 0, -1))
        let requestedUp = normalizedOrDefault(camera.up, SIMD3<Float>(0, 1, 0))
        var right = simd_cross(forward, requestedUp)
        if simd_length_squared(right) <= 0.000_001 {
            right = simd_cross(forward, SIMD3<Float>(1, 0, 0))
        }
        right = normalizedOrDefault(right, SIMD3<Float>(1, 0, 0))
        let up = normalizedOrDefault(simd_cross(right, forward), SIMD3<Float>(0, 1, 0))
        return CameraBasis(forward: forward, right: right, up: up)
    }

    private func renderDistanceFade(
        emitter: ParticleEmitter,
        toWorld: simd_float4x4,
        cameraEye: SIMD3<Float>
    ) -> Float {
        guard emitter.maxRenderDistance > 0 else {
            return 1
        }
        let origin = Self.transformPoint(emitter.originOffset, by: toWorld)
        let distance = simd_length(origin - cameraEye)
        guard distance <= emitter.maxRenderDistance else {
            return 0
        }
        guard emitter.renderDistanceFadeRange > 0 else {
            return 1
        }
        let fadeRange = min(emitter.renderDistanceFadeRange, emitter.maxRenderDistance)
        guard fadeRange > 0.0001 else {
            return 1
        }
        let fadeStart = emitter.maxRenderDistance - fadeRange
        guard distance > fadeStart else {
            return 1
        }
        return simd_clamp((emitter.maxRenderDistance - distance) / fadeRange, 0, 1)
    }

    private func emitterCameraDistance(
        emitter: ParticleEmitter,
        toWorld: simd_float4x4,
        cameraEye: SIMD3<Float>
    ) -> Float {
        let origin = Self.transformPoint(emitter.originOffset, by: toWorld)
        return simd_length(origin - cameraEye)
    }

    private func appendTrailParticles(
        for particle: Particle,
        emitter: ParticleEmitter,
        base: RenderParticle,
        worldVelocity: SIMD3<Float>,
        to result: inout [RenderParticle]
    ) {
        guard emitter.trailLength > 0,
              emitter.trailSegments > 0,
              particle.size > 0
        else { return }

        let speed = simd_length(worldVelocity)
        guard speed > 0.0001 else { return }

        let segmentCount = emitter.trailSegments
        let step = worldVelocity * (emitter.trailLength / Float(segmentCount))
        for index in 1...segmentCount {
            let t = Float(index) / Float(segmentCount)
            let sizeScale = 1 + (emitter.trailEndSizeScale - 1) * t
            let alphaScale = 1 + (emitter.trailEndAlphaScale - 1) * t
            var color = base.color
            color.w *= alphaScale
            result.append(
                RenderParticle(
                    position: base.position - step * Float(index),
                    size: max(0, base.size * sizeScale),
                    rotation: base.rotation,
                    color: color,
                    uvRect: base.uvRect,
                    alignmentAxis: base.alignmentAxis,
                    stretch: base.stretch,
                    blendMode: base.blendMode,
                    texturePath: base.texturePath
                )
            )
        }
    }

    private func renderAlignment(for emitter: ParticleEmitter,
                                 worldVelocity: SIMD3<Float>) -> (axis: SIMD3<Float>, stretch: Float) {
        guard emitter.renderAlignment == .velocity else {
            return (.zero, 1)
        }
        let speed = simd_length(worldVelocity)
        guard speed > 0.0001 else {
            return (.zero, 1)
        }
        let stretch = min(emitter.velocityStretchMax,
                          max(1, 1 + speed * emitter.velocityStretchScale))
        return (worldVelocity / speed, stretch)
    }

    private static func transformDirection(_ direction: SIMD3<Float>, by matrix: simd_float4x4) -> SIMD3<Float> {
        let transformed = matrix * SIMD4<Float>(direction, 0)
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    private static func transformPoint(_ point: SIMD3<Float>, by matrix: simd_float4x4) -> SIMD3<Float> {
        let transformed = matrix * SIMD4<Float>(point, 1)
        if abs(transformed.w) > 0.0001 {
            return SIMD3<Float>(
                transformed.x / transformed.w,
                transformed.y / transformed.w,
                transformed.z / transformed.w
            )
        }
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }

    private func selectRenderCamera(
        from view: RuntimeRenderReadView
    ) -> (entity: EntityID?, camera: RenderCamera, report: JobDispatchReport) {
        let candidates = jobSystem.parallelCompactMap(items: view.entities) { entity -> (EntityID, RenderCamera, Bool)? in
            guard let component = view.cameras[entity] else {
                return nil
            }

            let camera = RenderCamera(
                eye: view.worldTransforms[entity]?.translation ?? .zero,
                target: component.target,
                up: component.up,
                fovYRadians: component.fovYRadians,
                aspectRatio: component.aspectRatio,
                near: component.near,
                far: component.far
            )
            return (entity, camera, component.isActive)
        }

        var fallbackSelection: (entity: EntityID?, camera: RenderCamera)?
        for candidate in candidates.0 {
            if fallbackSelection == nil {
                fallbackSelection = (candidate.0, candidate.1)
            }
            if candidate.2 {
                return (candidate.0, candidate.1, candidates.1)
            }
        }

        let resolved = fallbackSelection ?? (nil, .fallbackPerspective)
        return (resolved.entity, resolved.camera, candidates.1)
    }

    private func collectRenderInstances(
        from view: RuntimeRenderReadView
    ) -> (instances: [ExtractedRenderInstance], report: JobDispatchReport) {
        let result = jobSystem.parallelCompactMap(items: view.entities) { entity -> ExtractedRenderInstance? in
            guard let renderMesh = view.renderMeshes[entity],
                  renderMesh.isVisible,
                  let worldTransform = view.worldTransforms[entity]
            else {
                return nil
            }

            return ExtractedRenderInstance(
                entity: entity,
                instance: RenderInstance(
                    mesh: RenderMeshHandle(meshIndex: renderMesh.meshIndex,
                                           assetID: renderMesh.assetID ?? view.assetReferences[entity]?.assetID),
                    transform: worldTransform.matrix,
                    colorTint: renderMesh.colorTint,
                    material: view.renderMaterials[entity]?.renderMaterial ?? .fallback,
                    entity: entity
                )
            )
        }
        return (result.0, result.1)
    }

    private func collectRenderLights(
        from view: RuntimeRenderReadView
    ) -> (lights: [ExtractedRenderLight], report: JobDispatchReport) {
        let result = jobSystem.parallelCompactMap(items: view.entities) { entity -> ExtractedRenderLight? in
            guard let component = view.lights[entity] else {
                return nil
            }
            let worldTransform = view.worldTransforms[entity] ?? .identity
            return ExtractedRenderLight(
                entity: entity,
                light: RenderLight(
                    type: component.renderLightType,
                    position: worldTransform.translation,
                    direction: renderForwardDirection(from: worldTransform.matrix),
                    color: component.color,
                    intensity: component.intensity,
                    range: component.range,
                    spotInnerAngleRadians: degreesToRadians(component.spotInnerAngleDegrees),
                    spotOuterAngleRadians: degreesToRadians(component.spotOuterAngleDegrees),
                    castShadows: component.castShadows,
                    entity: entity
                )
            )
        }
        return (result.0, result.1)
    }

    private func buildRenderReadView(in world: RuntimeWorld) -> RuntimeRenderReadView {
        let entities = world.entities()
        return RuntimeRenderReadView(
            entities: entities,
            worldTransforms: world.worldTransformSnapshot(matching: entities),
            cameras: world.componentSnapshot(CameraComponent.self, matching: entities),
            renderMeshes: world.componentSnapshot(RenderMeshComponent.self, matching: entities),
            renderMaterials: world.componentSnapshot(RenderMaterialComponent.self, matching: entities),
            lights: world.componentSnapshot(LightComponent.self, matching: entities),
            assetReferences: world.componentSnapshot(AssetReferenceComponent.self, matching: entities)
        )
    }

    private func buildPhysicsReadView(in world: RuntimeWorld) -> RuntimePhysicsReadView {
        let entities = world.entities()
        let colliders = world.componentSnapshot(Collider.self, matching: entities)
        let geometryResource = world.resource(MeshColliderGeometryResource.self)
        var meshGeometries: [EntityID: MeshColliderGeometry] = [:]
        for (entity, collider) in colliders {
            let resourceID = collider.shape.resourceID
            if let geometry = geometryResource?.geometry(for: resourceID) {
                meshGeometries[entity] = geometry
            }
        }
        return RuntimePhysicsReadView(
            entities: entities,
            localTransforms: world.localTransformSnapshot(matching: entities),
            worldTransforms: world.worldTransformSnapshot(matching: entities),
            rigidBodies: world.componentSnapshot(RigidBody.self, matching: entities),
            colliders: colliders,
            constraints: world.componentSnapshot(Constraint.self, matching: entities),
            meshGeometries: meshGeometries
        )
    }

    private func mergeDispatchReports(_ reports: [JobDispatchReport]) -> JobDispatchReport {
        JobDispatchReport.merged(reports, workerCount: jobSystem.workerCount)
    }
}

private extension LightComponent {
    var renderLightType: RenderLightType {
        switch type {
        case .directional:
            return .directional
        case .point:
            return .point
        case .spot:
            return .spot
        }
    }
}

private func degreesToRadians(_ degrees: Float) -> Float {
    degrees * .pi / 180
}

private func normalizedOrDefault(_ vector: SIMD3<Float>, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
    let lengthSquared = simd_length_squared(vector)
    guard lengthSquared > 0.000_001 else {
        return fallback
    }
    return vector / sqrt(lengthSquared)
}

private func renderForwardDirection(from matrix: simd_float4x4) -> SIMD3<Float> {
    let forward = -SIMD3<Float>(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
    let lengthSquared = simd_length_squared(forward)
    guard lengthSquared > 0.000001 else {
        return SIMD3<Float>(0, 0, -1)
    }
    return forward / sqrt(lengthSquared)
}

import Dispatch
import EngineKernel
import SIMDCompat
public struct RuntimeWorldSchedule {
    struct ExtractedRenderInstance {
        var entity: EntityID
        var instance: RenderInstance
    }

    struct ExtractedRenderLight {
        var entity: EntityID
        var light: RenderLight
    }

    struct SortableRenderParticle {
        var particle: RenderParticle
        var sortMode: ParticleSortMode
        var sortPriority: Int
        var distanceSquared: Float
        var age: Float
        var sourceOrder: Int
    }

    struct PhysicsSyncCache {
        var bodies: [EntityID: PhysicsBodyDescriptor] = [:]
        var constraints: [EntityID: PhysicsConstraintDescriptor] = [:]
        var vehicles: [EntityID: PhysicsVehicleDescriptor] = [:]
        var softBodies: [EntityID: PhysicsSoftBodyDescriptor] = [:]
    }

    struct RuntimePhysicsReadView {
        var entities: [EntityID]
        var localTransforms: [EntityID: LocalTransform]
        var worldTransforms: [EntityID: WorldTransform]
        var rigidBodies: [EntityID: RigidBody]
        var colliders: [EntityID: Collider]
        var constraints: [EntityID: Constraint]
        var characters: [EntityID: CharacterController]
        var vehicles: [EntityID: Vehicle]
        var softBodies: [EntityID: SoftBody]
        var cloths: [EntityID: Cloth]
        var softBodyMeshes: [EntityID: SoftBodyMesh]
        var meshGeometries: [EntityID: MeshColliderGeometry]
        var softBodyMeshGeometries: [EntityID: MeshColliderGeometry]
    }

    struct RuntimeRenderReadView {
        var entities: [EntityID]
        var worldTransforms: [EntityID: WorldTransform]
        var cameras: [EntityID: CameraComponent]
        var renderMeshes: [EntityID: RenderMeshComponent]
        var renderMaterials: [EntityID: RenderMaterialComponent]
        var lights: [EntityID: LightComponent]
        var cloths: [EntityID: Cloth]
        var softBodyMeshes: [EntityID: SoftBodyMesh]
        var softBodyMeshGeometries: [EntityID: MeshColliderGeometry]
        var assetReferences: [EntityID: AssetReferenceComponent]
    }

    var physicsBackend: any PhysicsBackend = NullPhysicsBackend()
    var explicitPhysicsBackend: (any PhysicsBackend)?
    var scriptDriver: (any RuntimeScriptDriver)?
    var physicsClock = PhysicsStepClockResource()
    var physicsFrameState = PhysicsFrameStateResource()
    var physicsContactFrame = PhysicsContactFrameResource.empty
    var physicsDebugFrame = PhysicsDebugFrameResource.empty
    var physicsEventFrame = PhysicsEventFrameResource.empty
    var characterStateFrame = CharacterStateFrameResource.empty
    var vehicleStateFrame = VehicleStateFrameResource.empty
    var softBodyStateFrame = SoftBodyStateFrameResource.empty
    var renderDeformableMeshes: [EntityID: RenderDeformableMesh] = [:]
    var ragdollSimulatedBodies: Set<EntityID> = []
    var physicsSyncCache = PhysicsSyncCache()
    var resolvedPhysicsBackendKind: PhysicsBackendKind = .none
    var jobSystem = JobSystem.shared
    let joltPhysicsBackend: JoltPhysicsBackend
    let physicsQueryScene: JoltPhysicsQueryScene

    public init() {
        let joltPhysicsBackend = JoltPhysicsBackend()
        self.joltPhysicsBackend = joltPhysicsBackend
        physicsQueryScene = JoltPhysicsQueryScene(backend: joltPhysicsBackend)
    }

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
        if let current = scriptDriver, current === driver {
            return
        }
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

    public var currentPhysicsContactFrame: PhysicsContactFrameResource {
        physicsContactFrame
    }

    public var currentPhysicsDebugFrame: PhysicsDebugFrameResource {
        physicsDebugFrame
    }

    public var currentPhysicsEventFrame: PhysicsEventFrameResource { physicsEventFrame }

    public var currentPhysicsQueryCacheStats: PhysicsQueryCacheStats {
        physicsQueryScene.stats
    }

    func physicsQueryBackend(in world: RuntimeWorld) -> JoltPhysicsBackend {
        physicsQueryScene.backend(in: world)
    }

    var physicsQuerySceneHandle: JoltPhysicsQueryScene {
        physicsQueryScene
    }

    public mutating func run(
        world: inout RuntimeWorld,
        commands: inout RuntimeCommandBuffer,
        deltaTimeSeconds: Double
    ) -> RuntimeScheduleReport {
        let drainedCommands = commands.drain()
        var frame = RuntimeFrameContext(
            physicsSettings: world.resource(PhysicsSettingsResource.self) ?? PhysicsSettingsResource()
        )
        // Preserve the last complete vertex stream when a render frame does not
        // accumulate enough time for a fixed physics step. Removed soft bodies
        // are pruned after descriptor collection below.
        frame.results.softBodyStates = softBodyStateFrame.states

        for phase in RuntimeSystemPhase.allCases {
            switch phase {
            case .commandApply:
                applyCommands(drainedCommands, world: &world, into: &frame)
            case .hierarchyPropagate:
                let report = world.propagateTransforms(using: jobSystem)
                frame.jobs.record(report, for: .hierarchyPropagate)
            case .inputAndPrePhysicsScripts:
                runPrePhysicsScripts(
                    world: &world,
                    commands: &commands,
                    into: &frame,
                    deltaTimeSeconds: deltaTimeSeconds
                )
            case .fixedPhysicsPrepare:
                prepareFixedPhysics(
                    world: &world,
                    into: &frame,
                    deltaTimeSeconds: deltaTimeSeconds
                )
            case .fixedPhysicsStep:
                stepFixedPhysics(
                    world: &world,
                    into: &frame,
                    deltaTimeSeconds: deltaTimeSeconds
                )
            case .physicsWriteback:
                writeBackPhysics(
                    world: &world,
                    into: &frame,
                    deltaTimeSeconds: deltaTimeSeconds
                )
            case .postPhysicsScripts:
                runPostPhysicsScripts(
                    world: &world,
                    commands: &commands,
                    into: &frame,
                    deltaTimeSeconds: deltaTimeSeconds
                )
            case .spatialIndexUpdate:
                updateSpatialIndex(world: &world, into: &frame)
            case .triggerDetection:
                detectTriggers(world: &world, into: &frame)
            case .renderExtract:
                let renderExtraction = extractRenderScene(in: world)
                world.setDerivedResource(renderExtraction.resource)
                frame.jobs.record(renderExtraction.report, for: .renderExtract)
            }
        }

        world.advanceRevision()
        world.setDerivedResource(CharacterCommandFrameResource.empty)
        world.setDerivedResource(VehicleCommandFrameResource.empty)
        world.setDerivedResource(DestructionCommandFrameResource.empty)

        return RuntimeScheduleReport(
            phases: RuntimeSystemPhase.allCases,
            commands: ScheduleCommandReport(
                appliedCount: drainedCommands.count,
                createdEntities: frame.createdEntities,
                destroyedEntities: frame.destroyedEntities
            ),
            physics: SchedulePhysicsReport(
                stepCount: frame.metrics.stepCount,
                writebackCount: frame.metrics.writebackCount,
                bodyCount: frame.metrics.bodyCount,
                softBodyCount: frame.metrics.softBodyCount,
                softBodyVertexCount: softBodyStateFrame.vertexCount,
                constraintCount: frame.metrics.constraintCount,
                contactCount: frame.metrics.contactCount,
                backendIdentifier: physicsBackend.identifier,
                synchronizationNanoseconds: frame.metrics.synchronizationNanoseconds,
                stepNanoseconds: frame.metrics.stepNanoseconds,
                droppedStepCount: physicsClock.lastDroppedStepCount,
                error: frame.metrics.error
            ),
            jobs: ScheduleJobReport(
                scheduledCount: frame.jobs.scheduledJobCount,
                workerCount: jobSystem.workerCount,
                parallelPhases: RuntimeSystemPhase.allCases.filter { frame.jobs.parallelPhases.contains($0) },
                phaseJobCounts: frame.jobs.phaseJobCounts
            ),
            revision: world.revision
        )
    }
}

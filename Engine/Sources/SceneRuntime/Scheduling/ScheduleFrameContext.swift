import EngineKernel

// MARK: - Per-frame schedule state

/// Physics descriptors collected during `fixedPhysicsPrepare` and consumed by the
/// step, writeback and trigger phases.
struct PhysicsFrameDescriptors {
    var bodies: [PhysicsBodyDescriptor] = []
    var constraints: [PhysicsConstraintDescriptor] = []
    var characters: [PhysicsCharacterDescriptor] = []
    var vehicles: [PhysicsVehicleDescriptor] = []
    var softBodies: [PhysicsSoftBodyDescriptor] = []
}

/// Simulation output produced by `fixedPhysicsStep`, published by `physicsWriteback`.
struct PhysicsFrameResults {
    var syncEvents: [PhysicsSyncEvent] = []
    var writebacks: [PhysicsBodyWriteback] = []
    var contactEvents: [PhysicsContactEvent] = []
    var jointBreakEvents: [PhysicsJointBreakEvent] = []
    var characterStates: [EntityID: CharacterState] = [:]
    var vehicleStates: [EntityID: VehicleState] = [:]
    var softBodyStates: [EntityID: SoftBodyMeshState] = [:]
}

/// Counters and timings surfaced through `RuntimeScheduleReport`.
struct PhysicsFrameMetrics {
    var stepCount = 0
    var writebackCount = 0
    var bodyCount = 0
    var softBodyCount = 0
    var constraintCount = 0
    var contactCount = 0
    var synchronizationNanoseconds: UInt64 = 0
    var stepNanoseconds: UInt64 = 0
    var synchronizedBodyCount = 0
    var synchronizedSoftBodyCount = 0
    var synchronizedConstraintCount = 0
    var error: PhysicsBackendError?
}

/// Commands captured for physics determinism recording and replay.
struct PhysicsFrameRecording {
    var bodyCommands: [PhysicsRecordedBodyCommand] = []
    var characterCommands: [PhysicsRecordedCharacterCommand] = []
    var vehicleCommands: [PhysicsRecordedVehicleCommand] = []
    var destructionCommands: [DestructionCommand] = []
    var destructionEvents = DestructionEventFrameResource.empty
}

/// Job-system usage accumulated across all phases.
struct JobFrameStats {
    var scheduledJobCount = 0
    var parallelPhases: Set<RuntimeSystemPhase> = []
    var phaseJobCounts: [RuntimeSystemPhase: Int] = [:]

    mutating func record(_ report: JobDispatchReport, for phase: RuntimeSystemPhase) {
        guard report.jobCount > 0 else { return }
        scheduledJobCount += report.jobCount
        phaseJobCounts[phase, default: 0] += report.jobCount
        if report.executedInParallel {
            parallelPhases.insert(phase)
        }
    }
}

/// Cross-phase mutable state for one `RuntimeWorldSchedule.run` call.
///
/// Grouping the accumulators lets each phase be a self-contained method instead of
/// one function carrying dozens of locals across a ten-case switch.
struct RuntimeFrameContext {
    var createdEntities: [EntityID] = []
    var destroyedEntities: [EntityID] = []
    var physicsSettings: PhysicsSettingsResource
    var descriptors = PhysicsFrameDescriptors()
    var results = PhysicsFrameResults()
    var metrics = PhysicsFrameMetrics()
    var recording = PhysicsFrameRecording()
    var jobs = JobFrameStats()
}

extension RuntimeWorldSchedule {
    func mergeDispatchReports(_ reports: [JobDispatchReport]) -> JobDispatchReport {
        JobDispatchReport.merged(reports, workerCount: jobSystem.workerCount)
    }
}

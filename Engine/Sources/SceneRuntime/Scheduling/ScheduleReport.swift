/// Command-buffer outcome of one `RuntimeWorldSchedule.run` call.
public struct ScheduleCommandReport: Sendable {
    public var appliedCount: Int
    public var createdEntities: [EntityID]
    public var destroyedEntities: [EntityID]

    public init(appliedCount: Int = 0,
                createdEntities: [EntityID] = [],
                destroyedEntities: [EntityID] = []) {
        self.appliedCount = appliedCount
        self.createdEntities = createdEntities
        self.destroyedEntities = destroyedEntities
    }
}

/// Physics counters and timings of one `RuntimeWorldSchedule.run` call.
///
/// Timings are nanoseconds accumulated across every substep of the frame; counters
/// describe the descriptors and results that reached the backend.
public struct SchedulePhysicsReport: Sendable {
    public var stepCount: Int
    public var writebackCount: Int
    public var bodyCount: Int
    public var softBodyCount: Int
    public var softBodyVertexCount: Int
    public var constraintCount: Int
    public var contactCount: Int
    public var backendIdentifier: String
    public var synchronizationNanoseconds: UInt64
    public var stepNanoseconds: UInt64
    public var droppedStepCount: Int
    public var error: PhysicsBackendError?

    public init(stepCount: Int = 0,
                writebackCount: Int = 0,
                bodyCount: Int = 0,
                softBodyCount: Int = 0,
                softBodyVertexCount: Int = 0,
                constraintCount: Int = 0,
                contactCount: Int = 0,
                backendIdentifier: String = "none",
                synchronizationNanoseconds: UInt64 = 0,
                stepNanoseconds: UInt64 = 0,
                droppedStepCount: Int = 0,
                error: PhysicsBackendError? = nil) {
        self.stepCount = stepCount
        self.writebackCount = writebackCount
        self.bodyCount = bodyCount
        self.softBodyCount = softBodyCount
        self.softBodyVertexCount = softBodyVertexCount
        self.constraintCount = constraintCount
        self.contactCount = contactCount
        self.backendIdentifier = backendIdentifier
        self.synchronizationNanoseconds = synchronizationNanoseconds
        self.stepNanoseconds = stepNanoseconds
        self.droppedStepCount = droppedStepCount
        self.error = error
    }
}

/// Job-system usage of one `RuntimeWorldSchedule.run` call.
public struct ScheduleJobReport: Sendable {
    public var scheduledCount: Int
    public var workerCount: Int
    public var parallelPhases: [RuntimeSystemPhase]
    public var phaseJobCounts: [RuntimeSystemPhase: Int]

    public init(scheduledCount: Int = 0,
                workerCount: Int = 1,
                parallelPhases: [RuntimeSystemPhase] = [],
                phaseJobCounts: [RuntimeSystemPhase: Int] = [:]) {
        self.scheduledCount = scheduledCount
        self.workerCount = workerCount
        self.parallelPhases = parallelPhases
        self.phaseJobCounts = phaseJobCounts
    }

    public func jobCount(for phase: RuntimeSystemPhase) -> Int {
        phaseJobCounts[phase] ?? 0
    }
}

/// Aggregated outcome of one `RuntimeWorldSchedule.run` call.
///
/// The report is a plain observable value: each group owns its own defaults so a
/// caller can build a partial report without naming every field.
public struct RuntimeScheduleReport: Sendable {
    public var phases: [RuntimeSystemPhase]
    public var commands: ScheduleCommandReport
    public var physics: SchedulePhysicsReport
    public var jobs: ScheduleJobReport
    public var revision: UInt64

    public init(phases: [RuntimeSystemPhase] = [],
                commands: ScheduleCommandReport = ScheduleCommandReport(),
                physics: SchedulePhysicsReport = SchedulePhysicsReport(),
                jobs: ScheduleJobReport = ScheduleJobReport(),
                revision: UInt64 = 0) {
        self.phases = phases
        self.commands = commands
        self.physics = physics
        self.jobs = jobs
        self.revision = revision
    }
}

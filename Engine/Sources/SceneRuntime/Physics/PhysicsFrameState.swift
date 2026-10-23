import Foundation
import SIMDCompat

public struct PhysicsStepClockResource: Sendable, Equatable {
    public var accumulatedSeconds: Double
    public var simulatedSteps: Int
    public var lastStepCount: Int
    public var lastSteppedSeconds: Double
    public var droppedSteps: Int
    public var lastDroppedStepCount: Int

    public init(
        accumulatedSeconds: Double = 0,
        simulatedSteps: Int = 0,
        lastStepCount: Int = 0,
        lastSteppedSeconds: Double = 0,
        droppedSteps: Int = 0,
        lastDroppedStepCount: Int = 0
    ) {
        self.accumulatedSeconds = accumulatedSeconds
        self.simulatedSteps = simulatedSteps
        self.lastStepCount = lastStepCount
        self.lastSteppedSeconds = lastSteppedSeconds
        self.droppedSteps = droppedSteps
        self.lastDroppedStepCount = lastDroppedStepCount
    }
}

/// Authored bodies the backend actually simulated this frame.
public struct PhysicsFrameBodyCounts: Sendable, Equatable {
    public var total: Int = 0
    public var soft: Int = 0
    public var softVertices: Int = 0
    public var constraints: Int = 0
    public var contacts: Int = 0
    public var writebacks: Int = 0

    public init(total: Int = 0, soft: Int = 0, softVertices: Int = 0,
                constraints: Int = 0, contacts: Int = 0, writebacks: Int = 0) {
        self.total = total
        self.soft = soft
        self.softVertices = softVertices
        self.constraints = constraints
        self.contacts = contacts
        self.writebacks = writebacks
    }
}

/// Entities synchronized from the simulation back into the scene this frame.
public struct PhysicsFrameSynchronization: Sendable, Equatable {
    public var bodies: Int = 0
    public var softBodies: Int = 0
    public var constraints: Int = 0
    /// Time spent copying simulation state into scene storage.
    public var nanoseconds: UInt64 = 0

    public init(bodies: Int = 0, softBodies: Int = 0, constraints: Int = 0,
                nanoseconds: UInt64 = 0) {
        self.bodies = bodies
        self.softBodies = softBodies
        self.constraints = constraints
        self.nanoseconds = nanoseconds
    }
}

public struct PhysicsFrameStateResource: Sendable, Equatable {
    public var backendIdentifier: String
    public var counts = PhysicsFrameBodyCounts()
    public var synchronization = PhysicsFrameSynchronization()
    public var simulatedSteps: Int
    public var simulatedSeconds: Double
    public var activeBodyCount: Int
    public var activeSoftBodyCount: Int
    public var droppedStepCount: Int
    public var stepNanoseconds: UInt64
    public var lastError: PhysicsBackendError?
    /// Authored features the active backend cannot simulate.
    public var unsupportedFeatures: PhysicsBackendCapabilities

    public init(
        backendIdentifier: String = "none",
        counts: PhysicsFrameBodyCounts = PhysicsFrameBodyCounts(),
        synchronization: PhysicsFrameSynchronization = PhysicsFrameSynchronization(),
        simulatedSteps: Int = 0,
        simulatedSeconds: Double = 0,
        activeBodyCount: Int = 0,
        activeSoftBodyCount: Int = 0,
        droppedStepCount: Int = 0,
        stepNanoseconds: UInt64 = 0,
        lastError: PhysicsBackendError? = nil,
        unsupportedFeatures: PhysicsBackendCapabilities = []
    ) {
        self.backendIdentifier = backendIdentifier
        self.counts = counts
        self.synchronization = synchronization
        self.simulatedSteps = simulatedSteps
        self.simulatedSeconds = simulatedSeconds
        self.activeBodyCount = activeBodyCount
        self.activeSoftBodyCount = activeSoftBodyCount
        self.droppedStepCount = droppedStepCount
        self.stepNanoseconds = stepNanoseconds
        self.lastError = lastError
        self.unsupportedFeatures = unsupportedFeatures
    }
}

public struct PhysicsStateHashFrameResource: Sendable, Equatable {
    public var simulatedStep: Int
    public var hash: UInt64

    public init(simulatedStep: Int = 0, hash: UInt64 = 0) {
        self.simulatedStep = simulatedStep
        self.hash = hash
    }

    public static let empty = PhysicsStateHashFrameResource()
}

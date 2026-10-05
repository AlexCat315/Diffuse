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

public struct PhysicsFrameStateResource: Sendable, Equatable {
    public var backendIdentifier: String
    public var bodyCount: Int
    public var softBodyCount: Int
    public var softBodyVertexCount: Int
    public var constraintCount: Int
    public var contactCount: Int
    public var writebackCount: Int
    public var simulatedSteps: Int
    public var simulatedSeconds: Double
    public var synchronizedBodyCount: Int
    public var synchronizedSoftBodyCount: Int
    public var synchronizedConstraintCount: Int
    public var activeBodyCount: Int
    public var activeSoftBodyCount: Int
    public var droppedStepCount: Int
    public var synchronizationNanoseconds: UInt64
    public var stepNanoseconds: UInt64
    public var lastError: PhysicsBackendError?

    public init(
        backendIdentifier: String = "none",
        bodyCount: Int = 0,
        softBodyCount: Int = 0,
        softBodyVertexCount: Int = 0,
        constraintCount: Int = 0,
        contactCount: Int = 0,
        writebackCount: Int = 0,
        simulatedSteps: Int = 0,
        simulatedSeconds: Double = 0,
        synchronizedBodyCount: Int = 0,
        synchronizedSoftBodyCount: Int = 0,
        synchronizedConstraintCount: Int = 0,
        activeBodyCount: Int = 0,
        activeSoftBodyCount: Int = 0,
        droppedStepCount: Int = 0,
        synchronizationNanoseconds: UInt64 = 0,
        stepNanoseconds: UInt64 = 0,
        lastError: PhysicsBackendError? = nil
    ) {
        self.backendIdentifier = backendIdentifier
        self.bodyCount = bodyCount
        self.softBodyCount = softBodyCount
        self.softBodyVertexCount = softBodyVertexCount
        self.constraintCount = constraintCount
        self.contactCount = contactCount
        self.writebackCount = writebackCount
        self.simulatedSteps = simulatedSteps
        self.simulatedSeconds = simulatedSeconds
        self.synchronizedBodyCount = synchronizedBodyCount
        self.synchronizedSoftBodyCount = synchronizedSoftBodyCount
        self.synchronizedConstraintCount = synchronizedConstraintCount
        self.activeBodyCount = activeBodyCount
        self.activeSoftBodyCount = activeSoftBodyCount
        self.droppedStepCount = droppedStepCount
        self.synchronizationNanoseconds = synchronizationNanoseconds
        self.stepNanoseconds = stepNanoseconds
        self.lastError = lastError
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

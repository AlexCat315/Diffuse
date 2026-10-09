// NativeRHI — queue submission descriptors and timeline semaphores.

public struct TimelineSemaphore: Hashable, Sendable {
    public var id: UInt32
    public var value: UInt64

    public init(id: UInt32, value: UInt64) {
        self.id = id
        self.value = value
    }
}

public struct SubmitDescriptor: Sendable {
    public var waitSemaphores: [TimelineSemaphore]
    public var signalSemaphores: [TimelineSemaphore]

    public init(
        waitSemaphores: [TimelineSemaphore] = [],
        signalSemaphores: [TimelineSemaphore] = []
    ) {
        self.waitSemaphores = waitSemaphores
        self.signalSemaphores = signalSemaphores
    }
}

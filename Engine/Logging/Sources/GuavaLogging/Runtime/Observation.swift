import Foundation

public final class LogObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var release: (@Sendable () -> Void)?
    init(_ release: @escaping @Sendable () -> Void) { self.release = release }
    public func cancel() { let work = lock.withLock { let work = release; release = nil; return work }; work?() }
    deinit { cancel() }
}

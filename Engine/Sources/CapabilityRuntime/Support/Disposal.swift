import Foundation

/// A disposal handle for one registration.
///
/// Every `DisposalScope.track` returns one of these; disposing it runs the
/// registered teardown exactly once. A registration that is disposed early and
/// then reached again by its scope's unwind is a no-op, so teardown cannot run
/// twice.
public struct Registration: Sendable {
    private let state = DisposalState()
    private let revoke: @Sendable () async -> Void

    public init(_ revoke: @escaping @Sendable () async -> Void) {
        self.revoke = revoke
    }

    /// Runs teardown once. Concurrent callers wait for the same completion.
    public func dispose() async {
        await state.task(for: revoke).value
    }
}

/// Runs a closure at most once across concurrent callers.
private final class DisposalState: @unchecked Sendable {
    private let lock = NSLock()
    private var disposal: Task<Void, Never>?

    func task(for revoke: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            if let disposal { return disposal }
            let task = Task { await revoke() }
            disposal = task
            return task
        }
    }
}

/// A LIFO scope that owns registrations and unwinds them as a group.
///
/// The scope is deliberately not a global registry: the object whose lifetime
/// the registrations follow (an exposure-session entry, an editor plugin
/// session, a host generation) owns one and releases it when that lifetime
/// ends. Unwinding runs each teardown exactly once, in reverse registration
/// order; the scope remains usable afterwards, so a long-lived owner can
/// dispose one generation and keep tracking the next.
public final class DisposalScope: @unchecked Sendable {
    private let lock = NSLock()
    private var registrations: [Registration] = []
    private var disposal: Task<Void, Never>?

    public init() {}

    /// Registers a teardown and returns its handle.
    @discardableResult
    public func track(_ revoke: @escaping @Sendable () async -> Void) -> Registration {
        let registration = Registration(revoke)
        track(registration)
        return registration
    }

    /// Takes ownership of an existing handle.
    ///
    /// A handle may be owned by one scope at a time; re-tracking a handle that
    /// an earlier scope already disposed stays a no-op because `Registration`
    /// is itself single-shot.
    public func track(_ registration: Registration) {
        lock.withLock { registrations.append(registration) }
    }

    /// Unwinds every outstanding registration in reverse registration order.
    ///
    /// Idempotent: after the first call, later calls do nothing until new
    /// registrations are tracked. Disposal of an individual registration
    /// before the unwind does not run its teardown twice.
    public func disposeAll() async {
        let task = lock.withLock {
            guard !registrations.isEmpty else { return disposal }
            let pending = registrations
            registrations.removeAll()
            let previous = disposal
            let next = Task {
                await previous?.value
                for registration in pending.reversed() {
                    await registration.dispose()
                }
            }
            disposal = next
            return next
        }
        await task?.value
    }
}

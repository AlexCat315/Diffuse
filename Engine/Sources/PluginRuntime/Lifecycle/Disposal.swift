import Foundation

/// An idempotent release operation. A scope always attempts every release.
public final class Registration: @unchecked Sendable {
    private let lock = NSLock()
    private var release: (@Sendable () throws -> Void)?

    public init(_ release: @escaping @Sendable () throws -> Void) { self.release = release }

    public func dispose() throws {
        let operation = lock.withLock { let operation = release; release = nil; return operation }
        try operation?()
    }
}

public final class DisposalScope: @unchecked Sendable {
    private let lock = NSLock()
    private var registrations: [Registration] = []
    private var isDisposed = false

    public init() {}

    public func own(_ registration: Registration) throws {
        let releaseNow = lock.withLock {
            if isDisposed { return true }
            registrations.append(registration)
            return false
        }
        if releaseNow { try registration.dispose() }
    }

    public func dispose() throws {
        let owned = lock.withLock { isDisposed = true; let owned = registrations; registrations = []; return owned }
        var failure: Error?
        for registration in owned.reversed() {
            do { try registration.dispose() } catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
    }
}


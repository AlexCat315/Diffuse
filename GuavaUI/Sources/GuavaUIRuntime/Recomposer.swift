import Foundation

/// Batches and deduplicates composition-scope recomposes within a single frame.
///
/// Data flow:
/// 1. A `@State` write fires `StateStorage.onChange`.
/// 2. The owning scope calls `Recomposer.shared.invalidate(scopeID:body:)`.
/// 3. A second call with the same `scopeID` in the same frame is dropped.
/// 4. The platform host calls `Recomposer.shared.commitAll()` at frame start,
///    executing all pending recomposes and clearing the queue.
public final class Recomposer: @unchecked Sendable {

    /// Singleton driven by `SDL3PlatformHost` in the default configuration.
    public static let shared = Recomposer()

    private var pending: [(id: ObjectIdentifier, body: () -> Void)] = []
    private let lock = NSLock()

    /// Create an independent instance — useful for tests.
    public init() {}

    // MARK: - Invalidation

    /// Schedule a recompose for `scopeID`.
    ///
    /// If `scopeID` is already queued for this frame the call is a no-op,
    /// so each scope recomposes at most once per frame regardless of how many
    /// state writes occur.
    public func invalidate(scopeID: ObjectIdentifier, body: @escaping () -> Void) {
        lock.withLock {
            guard !pending.contains(where: { $0.id == scopeID }) else { return }
            pending.append((id: scopeID, body: body))
        }
    }

    // MARK: - Commit

    /// Execute all pending recomposes in registration order, then clear the queue.
    ///
    /// Call once per frame, before flushing the `NodeTree`.
    public func commitAll() {
        let scopes = lock.withLock {
            let s = pending
            pending = []
            return s
        }
        for scope in scopes { scope.body() }
    }

    /// `true` when there are pending recomposes queued for the next `commitAll()`.
    public var hasPending: Bool {
        lock.withLock { !pending.isEmpty }
    }
}

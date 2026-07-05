import Foundation

/// Batches and deduplicates composition-scope recomposes within a single frame.
///
/// Data flow:
/// 1. A `@State` write fires `StateStorage.onChange`.
/// 2. The owning scope calls `recomposer.invalidate(scopeID:body:)` on the
///    `Recomposer` instance owned by the host.
/// 3. A second call with the same `scopeID` in the same frame is dropped.
/// 4. The platform host calls `recomposer.commitAll()` at frame start,
///    executing pending recomposes and any child-scope recomposes they queue
///    before layout/draw for that frame.
///
/// Each `PlatformHost` (and therefore each window) owns its own `Recomposer`
/// instance — see blueprint §9.4 windowing strategy.
public final class Recomposer: @unchecked Sendable {

    private struct PendingScope {
        let id: ObjectIdentifier
        let body: () -> Void
        /// Animation captured at write time. Re-established by `commitAll`
        /// before invoking `body` so modifier `apply` paths observe the same
        /// animation that the user authored at the call site.
        let animation: Animation?
    }

    private var pendingOrder: [ObjectIdentifier] = []
    private var pendingByID: [ObjectIdentifier: PendingScope] = [:]
    private var scanIndex = 0
    private let lock = NSLock()

    public init() {}

    // MARK: - Invalidation

    /// Schedule a recompose for `scopeID`.
    ///
    /// If `scopeID` is already queued for this frame the call is a no-op,
    /// so each scope recomposes at most once per frame regardless of how many
    /// state writes occur. `animation` defaults to `nil`; when non-nil,
    /// `commitAll` installs it as the active animation context for the
    /// duration of `body`.
    public func invalidate(scopeID: ObjectIdentifier,
                           animation: Animation? = nil,
                           body: @escaping () -> Void) {
        lock.withLock {
            guard pendingByID[scopeID] == nil else { return }
            pendingByID[scopeID] = PendingScope(id: scopeID,
                                                body: body,
                                                animation: animation)
            pendingOrder.append(scopeID)
        }
    }

    // MARK: - Commit

    /// Execute all pending recomposes in registration order, draining child
    /// invalidations queued by those recomposes before returning.
    ///
    /// A scope that invalidates itself while it is already being committed is
    /// left queued for the next frame; different child scopes are committed in
    /// the current frame so parent-driven environment changes settle before
    /// layout/draw.
    @discardableResult
    public func commitAll() -> Bool {
        var committedIDs = Set<ObjectIdentifier>()
        var didCommit = false

        while true {
            let scope: PendingScope? = lock.withLock {
                while scanIndex < pendingOrder.count {
                    let id = pendingOrder[scanIndex]
                    scanIndex += 1
                    guard let scope = pendingByID[id] else { continue }
                    guard !committedIDs.contains(id) else { continue }
                    pendingByID.removeValue(forKey: id)
                    return scope
                }
                return nil
            }
            guard let scope else { break }
            didCommit = true
            committedIDs.insert(scope.id)
            ActiveAnimationContext.with(scope.animation) {
                scope.body()
            }
        }

        compactPendingQueue()
        return didCommit
    }

    /// `true` when there are pending recomposes queued for the next `commitAll()`.
    public var hasPending: Bool {
        lock.withLock { !pendingByID.isEmpty }
    }

    private func compactPendingQueue() {
        lock.withLock {
            guard scanIndex > 0 else { return }
            pendingOrder = pendingOrder.filter { pendingByID[$0] != nil }
            scanIndex = 0
        }
    }
}

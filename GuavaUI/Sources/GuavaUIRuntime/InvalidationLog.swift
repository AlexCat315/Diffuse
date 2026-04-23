import Foundation

/// Why a node was marked dirty.
///
/// Phase 1 consumers (SceneInspector / DevTools) use this to attribute a
/// dirty propagation back to its source. Future phases will route these
/// records through scheduling decisions (e.g. layer-only vs full repaint).
public enum InvalidationSource: Sendable, Equatable {
    case stateWrite(scope: UInt64)
    case styleSet(field: String)
    case layoutChange
    case structuralChange
    case focusChange
    case platformResize
    case unknown
}

/// Which subsystem the dirtiness applies to.
public enum InvalidationPhase: String, Sendable {
    case layout
    case render
    case input
    case structure
}

/// One recorded invalidation event.
public struct DirtyReason: Sendable {
    public let target: ElementID
    public let source: InvalidationSource
    public let phase: InvalidationPhase
    public let timestamp: TimeInterval

    public init(target: ElementID,
                source: InvalidationSource,
                phase: InvalidationPhase,
                timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.target = target
        self.source = source
        self.phase = phase
        self.timestamp = timestamp
    }
}

/// Bounded ring buffer of recent `DirtyReason` entries.
///
/// Owned per-window. Threading: `record` is intended to be called from the
/// host actor that mutates the tree; an internal lock guards against debug
/// reads from another thread (e.g. DevTools).
public final class InvalidationLog: @unchecked Sendable {

    public static let defaultCapacity: Int = 256

    private let lock = NSLock()
    private var buffer: [DirtyReason]
    private var head: Int = 0
    private var count: Int = 0
    public let capacity: Int

    public init(capacity: Int = InvalidationLog.defaultCapacity) {
        self.capacity = max(1, capacity)
        self.buffer = []
        self.buffer.reserveCapacity(self.capacity)
    }

    public func record(_ reason: DirtyReason) {
        lock.lock()
        defer { lock.unlock() }
        if buffer.count < capacity {
            buffer.append(reason)
            count = buffer.count
            head = count % capacity
        } else {
            buffer[head] = reason
            head = (head + 1) % capacity
            count = capacity
        }
    }

    /// Returns recorded entries in oldest-to-newest order.
    public func snapshot(limit: Int? = nil) -> [DirtyReason] {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return [] }
        var out: [DirtyReason] = []
        out.reserveCapacity(count)
        if buffer.count < capacity {
            out.append(contentsOf: buffer)
        } else {
            for i in 0..<capacity {
                out.append(buffer[(head + i) % capacity])
            }
        }
        if let limit, out.count > limit {
            return Array(out.suffix(limit))
        }
        return out
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
        head = 0
        count = 0
    }
}

/// Per-window holder for the active invalidation log. Phase 1 uses an
/// implicit current-window holder so existing call sites can record without
/// being plumbed an explicit log reference. Set by `PlatformWindowSession`'s
/// `withCurrent { ... }` scope.
public enum InvalidationLogHolder {
    nonisolated(unsafe) public static var current: InvalidationLog?

    /// Run `body` with `log` installed as the current log. Restores the
    /// previous binding on exit.
    @discardableResult
    public static func with<R>(_ log: InvalidationLog?, _ body: () throws -> R) rethrows -> R {
        let previous = current
        current = log
        defer { current = previous }
        return try body()
    }
}

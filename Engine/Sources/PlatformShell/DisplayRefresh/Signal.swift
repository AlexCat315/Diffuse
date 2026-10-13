import Foundation

/// A native display callback, in monotonic host-clock seconds. The target is
/// the display's predicted presentation time, rather than a synthesized timer.
public struct DisplayRefreshTick: Sendable, Equatable {
    public let timestamp: Double
    public let targetTimestamp: Double

    public init(timestamp: Double, targetTimestamp: Double) {
        self.timestamp = timestamp
        self.targetTimestamp = targetTimestamp
    }
}

/// Native callbacks may arrive while a frame is blocked in drawable acquisition.
/// Retain only the newest signal and enqueue at most one event-loop wake.
final class DisplayRefreshInbox: @unchecked Sendable {
    private let lock = NSLock()
    private let wake: @Sendable () -> Void
    private var enabled = false
    private var latest: DisplayRefreshTick?

    init(wake: @escaping @Sendable () -> Void) {
        self.wake = wake
    }

    func setEnabled(_ enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
            if !enabled { latest = nil }
        }
    }

    func publish(_ tick: DisplayRefreshTick) {
        let shouldWake = lock.withLock {
            guard enabled else { return false }
            let wasEmpty = latest == nil
            latest = tick
            return wasEmpty
        }
        if shouldWake { wake() }
    }

    func take() -> DisplayRefreshTick? {
        lock.withLock {
            defer { latest = nil }
            return latest
        }
    }
}

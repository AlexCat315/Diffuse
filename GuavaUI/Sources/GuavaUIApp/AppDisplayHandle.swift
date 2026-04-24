import GuavaUIRuntime
import Foundation

public final class AppDisplayHandle: @unchecked Sendable {
    private final class Signal: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = false

        func request() {
            lock.withLock {
                pending = true
            }
        }

        func drain() -> Bool {
            lock.withLock {
                let wasPending = pending
                pending = false
                return wasPending
            }
        }
    }

    private let signal = Signal()

    public init() {}

    public nonisolated func requestDisplay() {
        signal.request()
    }

    func drainDisplayRequest() -> Bool {
        signal.drain()
    }
}

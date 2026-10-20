import Foundation

/// Storage behind a process-wide ambient pointer. Reads retain under the same
/// lock that swaps release under, so replacing the value can never free one
/// another thread is still loading (UI hosts swap on one thread; parallel
/// tests do not).
final class AmbientSlot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var current: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

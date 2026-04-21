import Foundation

final class LockedState<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.withLock {
            body(&value)
        }
    }
}

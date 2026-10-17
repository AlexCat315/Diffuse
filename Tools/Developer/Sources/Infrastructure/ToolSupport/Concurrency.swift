internal import Foundation

/// Minimal lock-guarded cell so synchronous wrappers can receive a value from a
/// concurrent completion handler without capturing a mutable local.
final class UncheckedBox<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value?

  func set(_ newValue: Value) {
    lock.lock()
    value = newValue
    lock.unlock()
  }

  func get() -> Value? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

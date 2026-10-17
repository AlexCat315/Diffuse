internal import Foundation

/// Lock-guarded cell so a synchronous entry point can hand values to, and
/// collect results from, a concurrency task without capturing a mutable local.
final class Box<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value?

  init(_ value: Value? = nil) { self.value = value }

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

internal import Foundation

/// A small lock-guarded cell. The harness keeps every CDP, socket, and process
/// callback on its own thread, so shared scalars live behind one of these
/// instead of loose mutable state.
final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value

  init(_ initial: Value) { stored = initial }

  var value: Value {
    get {
      lock.lock()
      defer { lock.unlock() }
      return stored
    }
    set {
      lock.lock()
      stored = newValue
      lock.unlock()
    }
  }

  func mutate<R>(_ body: (inout Value) -> R) -> R {
    lock.lock()
    defer { lock.unlock() }
    return body(&stored)
  }
}

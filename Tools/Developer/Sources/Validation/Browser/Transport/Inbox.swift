internal import Foundation

/// Socket callbacks and blocking CDP requests share only this condition-protected queue.
final class WebSocketInbox: @unchecked Sendable {
  private let condition = NSCondition()
  private var messages: [String] = []
  private var upgraded = false
  private var closed = false

  func open() {
    condition.lock()
    upgraded = true
    condition.broadcast()
    condition.unlock()
  }

  func waitForUpgrade(timeout: TimeInterval) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while !upgraded && !closed {
      if !condition.wait(until: deadline) { break }
    }
    return upgraded && !closed
  }

  func enqueue(_ text: String) {
    condition.lock()
    messages.append(text)
    condition.signal()
    condition.unlock()
  }

  func nextMessage(timeout: TimeInterval) -> String? {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while messages.isEmpty && !closed {
      if !condition.wait(until: deadline) { break }
    }
    return messages.isEmpty ? nil : messages.removeFirst()
  }

  var isClosed: Bool {
    condition.lock()
    defer { condition.unlock() }
    return closed
  }

  func close() {
    condition.lock()
    closed = true
    condition.broadcast()
    condition.unlock()
  }
}

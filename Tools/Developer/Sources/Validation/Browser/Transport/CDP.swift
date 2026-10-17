internal import Foundation
private import ToolSupport

/// A JSON-RPC connection to one Chrome DevTools Protocol target. Requests are
/// matched back by identifier, while events accumulate until the harness drains
/// them at the next safe point on the main thread.
final class CDPConnection: @unchecked Sendable {
  private let transport: WebSocketTransport
  private let condition = NSCondition()
  private var responses: [Int: JSON] = [:]
  private var events: [(method: String, params: JSON)] = []
  private var nextIdentifier = 1
  private var finished = false

  init(url: URL) throws {
    transport = try WebSocketTransport(url: url)
    startPump()
  }

  @discardableResult
  func request(_ method: String, _ params: JSON = .object([:]), timeout: TimeInterval = 60) throws
    -> JSON
  {
    let identifier: Int
    condition.lock()
    identifier = nextIdentifier
    nextIdentifier += 1
    condition.unlock()

    var message: [String: JSON] = ["id": .number(Double(identifier)), "method": .string(method)]
    if case .object(let object) = params, !object.isEmpty { message["params"] = params }
    try transport.send(JSON.object(message).serialized)

    condition.lock()
    let deadline = Date(timeIntervalSinceNow: timeout)
    while responses[identifier] == nil && !finished {
      if !condition.wait(until: deadline) { break }
    }
    let response = responses.removeValue(forKey: identifier)
    let closed = finished
    condition.unlock()

    guard let response else {
      if closed { throw ToolError.message("DevTools connection closed during \(method)") }
      throw ToolError.message("DevTools command timed out: \(method)")
    }
    if let error = response["error"], !error.isNull {
      throw ToolError.message("\(method): \(error["message"]?.string ?? error.serialized)")
    }
    return response["result"] ?? .object([:])
  }

  @discardableResult
  func drainEvents() -> [(method: String, params: JSON)] {
    condition.lock()
    defer { condition.unlock() }
    let drained = events
    events.removeAll()
    return drained
  }

  func close() {
    transport.close()
  }

  private func startPump() {
    let thread = Thread { [self] in
      while !transport.isClosed {
        guard let text = transport.nextMessage(timeout: 1), let message = try? JSON.parse(text)
        else { continue }
        if let identifier = message["id"]?.int {
          condition.lock()
          responses[identifier] = message
          condition.signal()
          condition.unlock()
        } else if let method = message["method"]?.string {
          condition.lock()
          events.append((method, message["params"] ?? .object([:])))
          condition.broadcast()
          condition.unlock()
        }
      }
      condition.lock()
      finished = true
      condition.broadcast()
      condition.unlock()
    }
    thread.stackSize = 8 << 20
    thread.start()
  }
}

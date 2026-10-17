internal import Foundation
private import ToolSupport

#if canImport(FoundationNetworking)
  internal import FoundationNetworking
#endif

/// Minimal synchronous WebSocket client used to speak the Chrome DevTools
/// Protocol. `URLSessionWebSocketTask` delivers messages on a delegate queue,
/// so a dedicated pump thread converts callbacks into a blocking queue.
final class WebSocketTransport: @unchecked Sendable {
  private let session: URLSession
  private let task: URLSessionWebSocketTask
  private let condition = NSCondition()
  private var queue: [String] = []
  private var failure: String?
  private var finished = false

  init(url: URL) throws {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 60
    configuration.timeoutIntervalForResource = 3600
    session = URLSession(configuration: configuration)
    task = session.webSocketTask(with: url)
    task.resume()
    startPump()
  }

  func send(_ text: String) throws {
    let box = Locked<Error?>(nil)
    let semaphore = DispatchSemaphore(value: 0)
    Task.detached { [task] in
      do { try await task.send(.string(text)) } catch { box.value = error }
      semaphore.signal()
    }
    semaphore.wait()
    if let error = box.value { throw ToolError.message("DevTools send failed: \(error)") }
  }

  func nextMessage(timeout: TimeInterval) -> String? {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while queue.isEmpty && failure == nil && !finished {
      if !condition.wait(until: deadline) { break }
    }
    return queue.isEmpty ? nil : queue.removeFirst()
  }

  var isClosed: Bool {
    condition.lock()
    defer { condition.unlock() }
    return finished || failure != nil
  }

  func close() {
    condition.lock()
    finished = true
    condition.broadcast()
    condition.unlock()
    task.cancel(with: .normalClosure, reason: nil)
    session.invalidateAndCancel()
  }

  private func startPump() {
    let thread = Thread { [self] in
      while true {
        let box = Locked<Result<URLSessionWebSocketTask.Message, Error>?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached { [task] in
          do { box.value = .success(try await task.receive()) } catch {
            box.value = .failure(error)
          }
          semaphore.signal()
        }
        semaphore.wait()
        guard let result = box.value else { return }
        switch result {
        case .success(.string(let text)):
          enqueue(text)
        case .success(.data(let data)):
          enqueue(String(decoding: data, as: UTF8.self))
        case .failure(let error):
          stop(with: String(describing: error))
          return
        @unknown default:
          return
        }
      }
    }
    thread.stackSize = 4 << 20
    thread.start()
  }

  private func enqueue(_ text: String) {
    condition.lock()
    queue.append(text)
    condition.signal()
    condition.unlock()
  }

  private func stop(with message: String?) {
    condition.lock()
    failure = message
    finished = true
    condition.broadcast()
    condition.unlock()
  }
}

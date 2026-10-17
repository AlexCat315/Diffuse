internal import Foundation
internal import ToolSupport

#if canImport(FoundationNetworking)
  internal import FoundationNetworking
#endif

#if canImport(Darwin)

  /// One DevTools WebSocket connection to a running editor. Each replaced Swift
  /// script opened its own `URLSessionWebSocketTask` with a cancel deadline; this
  /// keeps that shape for query, input, capture, timings and session checks.
  final class DevToolsSocket {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let expired = Box(false)
    private var deadline: DispatchWorkItem?

    init(url: URL, timeout: TimeInterval?, maximumMessageSize: Int) {
      session = URLSession(configuration: .ephemeral)
      socket = session.webSocketTask(with: url)
      socket.maximumMessageSize = maximumMessageSize
      socket.resume()
      if let timeout { armTimeout(timeout) }
    }

    /// `ws://127.0.0.1:PORT/` with this process's optional DevTools token.
    static func loopback(port: UInt16, token: Bool) -> URL? {
      var components = URLComponents()
      components.scheme = "ws"
      components.host = "127.0.0.1"
      components.port = Int(port)
      components.path = "/"
      if token, let value = ProcessInfo.processInfo.environment["GUAVA_DEVTOOLS_TOKEN"],
        !value.isEmpty
      {
        components.queryItems = [URLQueryItem(name: "token", value: value)]
      }
      return components.url
    }

    var hasExpired: Bool { expired.get() == true }

    /// Cancels the connection if it is still alive after `interval`.
    func armTimeout(_ interval: TimeInterval) {
      deadline?.cancel()
      let expired = self.expired
      let socket = self.socket
      let item = DispatchWorkItem {
        expired.set(true)
        socket.cancel(with: .goingAway, reason: nil)
      }
      deadline = item
      DispatchQueue.global().asyncAfter(deadline: .now() + interval, execute: item)
    }

    func close() {
      deadline?.cancel()
      socket.cancel(with: .normalClosure, reason: nil)
      session.invalidateAndCancel()
    }

    func send(_ object: [String: Any]) async throws {
      let text = String(decoding: try JSON.data(object), as: UTF8.self)
      try await socket.send(.string(text))
    }

    func receive() async throws -> [String: Any] {
      let message: URLSessionWebSocketTask.Message
      do { message = try await socket.receive() } catch {
        throw ToolError.message(error.localizedDescription)
      }
      switch message {
      case .data(let data): return try JSON.parseObject(data)
      case .string(let text): return try JSON.parseObject(Data(text.utf8))
      @unknown default: throw ToolError.message("Unknown WebSocket message")
      }
    }

    /// Receive with a fresh deadline, distinguishing an expired deadline.
    func receive(timeout: TimeInterval) async throws -> [String: Any] {
      armTimeout(timeout)
      do { return try await receive() } catch {
        if hasExpired { throw ToolError.message("Timed out waiting for a DevTools message") }
        throw error
      }
    }

    /// Throws on a `.err` envelope, matching the capture and timing scripts.
    func receiveEnvelope() async throws -> [String: Any] {
      let envelope = try await receive()
      if (envelope["type"] as? String)?.hasSuffix(".err") == true {
        throw ToolError.message(JSON.text(envelope))
      }
      return envelope
    }
  }

#endif

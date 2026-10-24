internal import Foundation
private import ToolSupport
private import NIOCore
private import NIOPosix
private import NIOHTTP1
private import NIOWebSocket

/// Blocking CDP boundary backed by the same socket implementation on macOS and Linux.
final class WebSocketTransport: Sendable {
  private let channel: any Channel
  private let inbox: WebSocketInbox

  init(url: URL) throws {
    guard url.scheme == "ws", let host = url.host else {
      throw ToolError.message("DevTools requires a ws:// endpoint")
    }
    let inbox = WebSocketInbox()
    let channel = try ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
      .connectTimeout(.seconds(10))
      .channelInitializer { channel in
        let upgrader = NIOWebSocketClientUpgrader(maxFrameSize: 32 << 20) { channel, _ in
          channel.pipeline.addHandler(WebSocketReceiver(inbox: inbox)).map { inbox.open() }
        }
        return channel.pipeline.addHTTPClientHandlers(
          withClientUpgrade: ([upgrader], { _ in }))
      }
      .connect(host: host, port: url.port ?? 80).wait()
    do {
      var headers = HTTPHeaders()
      headers.add(name: "Host", value: url.port.map { "\(host):\($0)" } ?? host)
      var uri = url.path.isEmpty ? "/" : url.path
      if let query = url.query { uri += "?" + query }
      let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri, headers: headers)
      try channel.writeAndFlush(HTTPClientRequestPart.head(head)).wait()
      try channel.writeAndFlush(HTTPClientRequestPart.end(nil)).wait()
      guard inbox.waitForUpgrade(timeout: 10) else {
        throw ToolError.message("DevTools WebSocket upgrade failed")
      }
    } catch {
      try? channel.close().wait()
      throw error
    }
    self.channel = channel
    self.inbox = inbox
  }

  func send(_ text: String) throws {
    let frame = WebSocketFrame(fin: true, opcode: .text, maskKey: .random(), data: ByteBuffer(string: text))
    try channel.writeAndFlush(frame).wait()
  }

  func nextMessage(timeout: TimeInterval) -> String? { inbox.nextMessage(timeout: timeout) }
  var isClosed: Bool { inbox.isClosed }

  func close() {
    inbox.close()
    channel.close(promise: nil)
  }

  deinit { channel.close(promise: nil) }
}

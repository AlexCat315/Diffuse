internal import Foundation
private import ToolSupport

#if canImport(Darwin)
  internal import Darwin
#elseif canImport(Glibc)
  internal import Glibc
#endif

/// A tiny threading socket server with `ThreadingHTTPServer` semantics: one
/// thread per connection, HTTP/1.0 responses closed after they finish, and a
/// configurable listen backlog. It replaces `http.server` for the verification
/// and development servers without depending on Python.
final class HTTPServer: @unchecked Sendable {
  typealias Handler = @Sendable (HTTPRequest, HTTPResponse) -> Void

  let port: Int
  private let listener: Int32
  private let handler: Handler
  private let running = Locked(true)
  private var closed = false

  init(
    port requestedPort: Int, bindAddress: String = "127.0.0.1", backlog: Int = 32,
    handler: @escaping Handler
  ) throws {
    let descriptor = socket(AF_INET, streamSocketType, 0)
    guard descriptor >= 0 else {
      throw ToolError.message("Cannot create server socket: \(String(cString: strerror(errno)))")
    }
    var reuse: Int32 = 1
    setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_in()
    #if canImport(Darwin)
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(requestedPort).bigEndian)
    guard inet_pton(AF_INET, bindAddress, &address.sin_addr) == 1 else {
      close(descriptor)
      throw ToolError.message("Invalid bind address: \(bindAddress)")
    }
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else {
      let message = String(cString: strerror(errno))
      close(descriptor)
      throw ToolError.message("Cannot bind \(bindAddress):\(requestedPort): \(message)")
    }
    guard listen(descriptor, Int32(backlog)) == 0 else {
      let message = String(cString: strerror(errno))
      close(descriptor)
      throw ToolError.message("Cannot listen on \(bindAddress):\(requestedPort): \(message)")
    }
    var resolved = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &resolved) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    self.listener = descriptor
    self.port = Int(UInt16(bigEndian: resolved.sin_port))
    self.handler = handler
  }

  func start() {
    let thread = Thread { [self] in acceptLoop() }
    thread.stackSize = 1 << 20
    thread.start()
  }

  func stop() {
    guard !closed else { return }
    closed = true
    running.value = false
    shutdown(listener, Int32(SHUT_RDWR))
    close(listener)
  }

  private func acceptLoop() {
    while running.value {
      var address = sockaddr_storage()
      var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
      let client = withUnsafeMutablePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
          accept(listener, $0, &length)
        }
      }
      if client < 0 {
        if !running.value { break }
        if errno == EINTR || errno == ECONNABORTED { continue }
        break
      }
      let thread = Thread { [self] in serve(client) }
      thread.stackSize = 1 << 20
      thread.start()
    }
  }

  private func serve(_ client: Int32) {
    defer { close(client) }
    #if canImport(Darwin)
      var noSignal: Int32 = 1
      setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    #endif
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    guard let head = readHead(client) else { return }
    let separator = Data("\r\n\r\n".utf8)
    let boundary = head.range(of: separator)
    let headBytes = boundary.map { head[head.startIndex..<$0.lowerBound] } ?? head[...]
    var body = boundary.map { Data(head[$0.upperBound...]) } ?? Data()
    guard var request = HTTPRequest.parse(head: Data(headBytes), body: Data()) else { return }
    if let declared = request.headers["content-length"], let count = Int(declared),
      count > body.count
    {
      while body.count < count {
        var chunk = [UInt8](repeating: 0, count: min(65536, count - body.count))
        let got = read(client, &chunk, chunk.count)
        if got <= 0 { break }
        body.append(contentsOf: chunk[0..<got])
      }
    }
    request.body = body
    let response = HTTPResponse { data in self.writeAll(client, data) }
    handler(request, response)
  }

  private func readHead(_ client: Int32) -> Data? {
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 8192)
    let separator = Data("\r\n\r\n".utf8)
    while buffer.count < 1 << 16 {
      let count = read(client, &chunk, chunk.count)
      if count <= 0 { return buffer.isEmpty ? nil : buffer }
      buffer.append(contentsOf: chunk[0..<count])
      if buffer.range(of: separator) != nil { break }
    }
    return buffer.isEmpty ? nil : buffer
  }

  private func writeAll(_ client: Int32, _ data: Data) -> Bool {
    var offset = 0
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
      guard let base = raw.baseAddress else { return true }
      while offset < data.count {
        #if canImport(Glibc)
          let written = send(
            client, base.advanced(by: offset), data.count - offset, Int32(MSG_NOSIGNAL))
        #else
          let written = send(client, base.advanced(by: offset), data.count - offset, 0)
        #endif
        if written <= 0 { return false }
        offset += written
      }
      return true
    }
  }
}

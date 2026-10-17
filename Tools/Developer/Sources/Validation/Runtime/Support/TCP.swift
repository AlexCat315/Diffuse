internal import Foundation
internal import ToolSupport

#if canImport(Darwin)
  internal import Darwin
#elseif canImport(Glibc)
  internal import Glibc
#endif

/// Line-oriented loopback TCP client used for the editor's JSON bridge and for
/// waiting until that bridge accepts connections.
final class TCPClient {
  private let descriptor: Int32
  private var buffer = Data()
  private var closed = false

  init(host: String, port: UInt16, timeout: TimeInterval) throws {
    descriptor = socket(AF_INET, POSIXIO.streamSocketType, 0)
    guard descriptor >= 0 else { throw ToolError.message("socket failed: \(POSIXIO.errorText())") }
    var address = sockaddr_in()
    #if canImport(Darwin)
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr(host)

    let flags = fcntl(descriptor, F_GETFL, 0)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    let connected = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if connected != 0, errno != EINPROGRESS {
      let code = errno
      closeDescriptor()
      throw ToolError.message("connect to \(host):\(port) failed: \(POSIXIO.errorText(code))")
    }
    if connected != 0 {
      guard try POSIXIO.writable(descriptor, timeout: timeout) else {
        closeDescriptor()
        throw ToolError.message("connect to \(host):\(port) timed out")
      }
      var failure: Int32 = 0
      var length = socklen_t(MemoryLayout<Int32>.size)
      let status = getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length)
      guard status == 0, failure == 0 else {
        let code = failure == 0 ? errno : failure
        closeDescriptor()
        throw ToolError.message("connect to \(host):\(port) failed: \(POSIXIO.errorText(code))")
      }
    }
    _ = fcntl(descriptor, F_SETFL, flags)
  }

  deinit { closeDescriptor() }

  func send(_ data: Data) throws { try POSIXIO.write(descriptor, data) }

  func readLine(timeout: TimeInterval = 5) throws -> Data {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
      if let index = buffer.firstIndex(of: 0x0A) {
        let line = buffer.subdata(in: buffer.startIndex..<index)
        buffer.removeSubrange(buffer.startIndex...index)
        return line
      }
      let remaining = deadline.timeIntervalSinceNow
      if remaining <= 0 {
        guard !buffer.isEmpty else {
          throw ToolError.message("Timed out waiting for a bridge reply")
        }
        let line = buffer
        buffer = Data()
        return line
      }
      if try POSIXIO.readable([descriptor], timeout: remaining).isEmpty { continue }
      guard let chunk = POSIXIO.read(descriptor, upTo: 65536) else {
        let line = buffer
        buffer = Data()
        return line
      }
      buffer.append(chunk)
    }
  }

  func close() { closeDescriptor() }

  private func closeDescriptor() {
    guard !closed else { return }
    closed = true
    POSIXIO.close(descriptor)
  }
}

/// Asks the kernel for an unused loopback port, the way the Python originals
/// bound a probe socket to port 0.
enum FreePort {
  static func reserve() throws -> UInt16 {
    let descriptor = socket(AF_INET, POSIXIO.streamSocketType, 0)
    guard descriptor >= 0 else { throw ToolError.message("socket failed: \(POSIXIO.errorText())") }
    defer { POSIXIO.close(descriptor) }
    var address = sockaddr_in()
    #if canImport(Darwin)
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0 else { throw ToolError.message("bind failed: \(POSIXIO.errorText())") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    var boundAddress = sockaddr_in()
    let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard named == 0 else { throw ToolError.message("getsockname failed: \(POSIXIO.errorText())") }
    return UInt16(bigEndian: boundAddress.sin_port)
  }
}

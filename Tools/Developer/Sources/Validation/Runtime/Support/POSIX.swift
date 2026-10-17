internal import Foundation
internal import ToolSupport

#if canImport(Darwin)
  internal import Darwin
#elseif canImport(Glibc)
  internal import Glibc
#endif

/// Raw descriptor IO with deadlines. The Python originals used `select` and
/// `selectors`; `poll` is the same idea with a millisecond timeout.
enum POSIXIO {
  static var streamSocketType: Int32 {
    #if canImport(Glibc)
      Int32(SOCK_STREAM.rawValue)
    #else
      SOCK_STREAM
    #endif
  }

  static func close(_ descriptor: Int32) {
    #if canImport(Darwin)
      Darwin.close(descriptor)
    #else
      Glibc.close(descriptor)
    #endif
  }
  /// Descriptors that are readable, hung up or in error within `timeout`.
  static func readable(_ descriptors: [Int32], timeout: TimeInterval) throws -> [Int32] {
    try ready(descriptors, events: Int16(POLLIN), timeout: timeout)
  }

  static func writable(_ descriptor: Int32, timeout: TimeInterval) throws -> Bool {
    try !ready([descriptor], events: Int16(POLLOUT), timeout: timeout).isEmpty
  }

  private static func ready(_ descriptors: [Int32], events: Int16, timeout: TimeInterval) throws
    -> [Int32]
  {
    guard !descriptors.isEmpty else { return [] }
    var entries = descriptors.map { pollfd(fd: $0, events: events, revents: 0) }
    let milliseconds = Int32(clamping: Int((max(0, timeout) * 1000).rounded(.up)))
    let ready = entries.withUnsafeMutableBufferPointer { buffer in
      poll(buffer.baseAddress, nfds_t(buffer.count), milliseconds)
    }
    if ready < 0 {
      if errno == EINTR { return [] }
      throw ToolError.message("poll failed: \(errorText())")
    }
    if ready == 0 { return [] }
    return zip(descriptors, entries).filter { $0.1.revents != 0 }.map { $0.0 }
  }

  /// One read; `nil` means end of file.
  static func read(_ descriptor: Int32, upTo count: Int) -> Data? {
    var bytes = [UInt8](repeating: 0, count: count)
    let received = bytes.withUnsafeMutableBytes { raw in
      #if canImport(Darwin)
        Darwin.read(descriptor, raw.baseAddress, raw.count)
      #else
        Glibc.read(descriptor, raw.baseAddress, raw.count)
      #endif
    }
    if received <= 0 { return nil }
    return Data(bytes[0..<received])
  }

  static func write(_ descriptor: Int32, _ data: Data) throws {
    var offset = 0
    try data.withUnsafeBytes { raw in
      guard let base = raw.baseAddress else { return }
      while offset < raw.count {
        #if canImport(Darwin)
          let written = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
        #else
          let written = Glibc.write(descriptor, base.advanced(by: offset), raw.count - offset)
        #endif
        if written < 0 {
          if errno == EINTR { continue }
          throw ToolError.message("write failed: \(errorText())")
        }
        offset += written
      }
    }
  }

  static func errorText(_ code: Int32 = errno) -> String { String(cString: strerror(code)) }
}

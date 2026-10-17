internal import Foundation
private import ToolSupport

#if canImport(FoundationNetworking)
  internal import FoundationNetworking
#endif
#if canImport(Darwin)
  internal import Darwin
#elseif canImport(Glibc)
  internal import Glibc
#endif

/// A blocking HTTP GET, used to discover the Chromium DevTools endpoint before
/// the WebSocket is available.
enum SystemHTTP {
  static func get(_ url: URL, timeout: TimeInterval = 5) throws -> (status: Int, body: Data) {
    var request = URLRequest(url: url)
    request.timeoutInterval = timeout
    request.cachePolicy = .reloadIgnoringLocalCacheData
    return try perform(request)
  }

  static func perform(_ request: URLRequest) throws -> (status: Int, body: Data) {
    let semaphore = DispatchSemaphore(value: 0)
    let result = Locked<Result<(Int, Data), Error>?>(nil)
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
      if let error {
        result.value = .some(.failure(error))
      } else if let http = response as? HTTPURLResponse {
        result.value = .some(.success((http.statusCode, data ?? Data())))
      } else {
        result.value = .some(
          .failure(ToolError.message("No HTTP response for \(request.url?.absoluteString ?? "")")))
      }
      semaphore.signal()
    }
    task.resume()
    semaphore.wait()
    switch result.value {
    case .success(let value): return value
    case .failure(let error): throw error
    case nil: throw ToolError.message("HTTP request did not complete")
    }
  }
}

/// Reserves an ephemeral loopback port the way `socket.bind(("127.0.0.1", 0))`
/// does before a child process is told which port to use.
func freePort() throws -> Int {
  let descriptor = socket(AF_INET, streamSocketType, 0)
  guard descriptor >= 0 else { throw ToolError.message("Cannot create a reservation socket") }
  defer { close(descriptor) }
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = 0
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  guard bound == 0 else { throw ToolError.message("Cannot reserve a loopback port") }
  var resolved = sockaddr_in()
  var length = socklen_t(MemoryLayout<sockaddr_in>.size)
  _ = withUnsafeMutablePointer(to: &resolved) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      getsockname(descriptor, $0, &length)
    }
  }
  return Int(UInt16(bigEndian: resolved.sin_port))
}

/// Probes a loopback port with a short connect, matching the native probe's
/// readiness check in the reference script.
func canConnect(port: Int, timeout: TimeInterval = 0.2) -> Bool {
  let descriptor = socket(AF_INET, streamSocketType, 0)
  guard descriptor >= 0 else { return false }
  defer { close(descriptor) }
  var value = timeval(
    tv_sec: Int(timeout), tv_usec: suseconds_t((timeout - floor(timeout)) * 1_000_000))
  setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &value, socklen_t(MemoryLayout<timeval>.size))
  var address = sockaddr_in()
  address.sin_family = sa_family_t(AF_INET)
  address.sin_port = in_port_t(UInt16(port).bigEndian)
  address.sin_addr.s_addr = inet_addr("127.0.0.1")
  let result = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
    }
  }
  return result == 0
}

var streamSocketType: Int32 {
  #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
  #else
    SOCK_STREAM
  #endif
}

import Foundation
import XCTest

@testable import RuntimeValidation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

final class ConnectionTests: XCTestCase {
  func testConnectCompletesBeforeServerSendsData() throws {
    let listener = socket(AF_INET, POSIXIO.streamSocketType, 0)
    XCTAssertGreaterThanOrEqual(listener, 0)
    defer { POSIXIO.close(listener) }
    var address = sockaddr_in()
    #if canImport(Darwin)
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    #endif
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        #if canImport(Darwin)
          Darwin.bind(listener, $0, length)
        #else
          Glibc.bind(listener, $0, length)
        #endif
      }
    }
    XCTAssertEqual(bound, 0)
    XCTAssertEqual(listen(listener, 1), 0)
    let named = withUnsafeMutablePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(listener, $0, &length)
      }
    }
    XCTAssertEqual(named, 0)
    let client = try TCPClient(
      host: "127.0.0.1", port: UInt16(bigEndian: address.sin_port), timeout: 0.2)
    client.close()
  }
}

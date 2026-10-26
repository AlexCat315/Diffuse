private import Foundation
internal import XCTest
@testable private import RuntimeValidation

final class EndpointTests: XCTestCase {
  func testPortsUseTheOptionalProcessToken() throws {
    let endpoint = try DevToolsEndpoint.resolve("9250", environment: ["COVE_DEVTOOLS_TOKEN": "test-token"])
    XCTAssertEqual(endpoint.port, 9250)
    XCTAssertEqual(URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.queryItems,
                   [URLQueryItem(name: "token", value: "test-token")])
    XCTAssertNil(try DevToolsEndpoint.resolve("9250", environment: [:]).query)
    for input in ["0", "65536", "@", "ws://example.org:9250/"] {
      XCTAssertThrowsError(try DevToolsEndpoint.resolve(input))
    }
  }

  func testDiscoveryAndManagedSessionsPreserveAuthenticationAndForwardedPorts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DevTools session with spaces \(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let runtime: [String: Any] = ["id": "example", "pid": 123, "endpoint": "ws://127.0.0.1:9250/?token=fixture-token"]
    for session: [String: Any] in [runtime, ["runtime": runtime], ["runtime": runtime, "device": ["forwardedPort": 12345]]] {
      let file = directory.appendingPathComponent("session.json")
      try JSONSerialization.data(withJSONObject: session).write(to: file)
      let endpoint = try DevToolsEndpoint.resolve("@" + file.path, environment: [:])
      XCTAssertEqual(endpoint.port, session["device"] == nil ? 9250 : 12345)
      XCTAssertEqual(URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "fixture-token")
    }
  }

  func testMalformedSessionsDoNotTurnIntoOtherNetworkTargets() {
    for endpoint in ["https://127.0.0.1:9250/", "ws://example.org:9250/", "ws://127.0.0.1/", "ws://user:pass@127.0.0.1:9250/"] {
      XCTAssertThrowsError(try DevToolsEndpoint.session(["endpoint": endpoint]))
    }
    for port: Any in [0, 65536, 3.5, true, "9250"] {
      XCTAssertThrowsError(try DevToolsEndpoint.session(["runtime": ["endpoint": "ws://localhost:9250/"], "device": ["forwardedPort": port]]))
    }
    XCTAssertThrowsError(try DevToolsEndpoint.session([:]))
  }
}

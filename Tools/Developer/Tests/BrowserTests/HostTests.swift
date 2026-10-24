import Foundation
import XCTest

@testable import Browser

final class HostTests: XCTestCase {
  func testDebuggerEndpointMatchesTheLaunchedBrowser() {
    let address = "ws://127.0.0.1:41234/devtools/browser/fixture"
    XCTAssertEqual(Chromium.debuggingEndpoint(from: "startup log\nDevTools listening on \(address)\n", port: 41234)?.absoluteString, address)
    for rejected in [address.replacingOccurrences(of: "41234", with: "41235"),
                     address.replacingOccurrences(of: "127.0.0.1", with: "example.com"),
                     address.replacingOccurrences(of: "ws:", with: "http:"),
                     address.replacingOccurrences(of: "/browser/", with: "/page/")] {
      XCTAssertNil(Chromium.debuggingEndpoint(from: "DevTools listening on \(rejected)\n", port: 41234))
    }
    XCTAssertNil(Chromium.debuggingEndpoint(from: "DevTools listening on ws://127.", port: 41234))
  }

  func testHTTPServerServesRealRequestsAndMissingFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("Swift HTTP fixture".utf8).write(to: root.appendingPathComponent("index.html"))
    let server = try staticServer(directory: root)
    server.start()
    defer { server.stop() }
    let base = URL(string: "http://127.0.0.1:\(server.port)/")!
    let response = try SystemHTTP.get(base)
    XCTAssertEqual(response.status, 200)
    XCTAssertEqual(String(decoding: response.body, as: UTF8.self), "Swift HTTP fixture")
    XCTAssertEqual(try SystemHTTP.get(base.appendingPathComponent("missing")).status, 404)
  }

  func testRealChromiumProtocolAndScreenshot() throws {
    guard ProcessInfo.processInfo.environment["GUAVA_TEST_CHROMIUM"] == "1" else {
      throw XCTSkip("Set GUAVA_TEST_CHROMIUM=1 to exercise an installed Chromium")
    }
    let server = try HTTPServer(port: 0) { _, response in
      response.send(
        status: 200, headers: ["Content-Type": "text/html"],
        body: Data(
          "<html><body style='background:rgb(220,30,40)'>Swift CDP fixture</body></html>".utf8))
    }
    server.start()
    defer { server.stop() }
    let address = "http://127.0.0.1:\(server.port)/"
    let browser = try ChromiumBrowser.launch(executable: nil, arguments: [])
    defer { browser.close() }
    let page = try browser.newPage()
    try page.goto(address)
    XCTAssertEqual(try page.evaluate("6 * 7").int, 42)
    let image = try page.elementImage("body")
    XCTAssertGreaterThan(image.width, 0)
    XCTAssertGreaterThan(image.height, 0)
    XCTAssertTrue(
      image.crop(20, 80, 21, 81).contains { $0.r == 220 && $0.g == 30 && $0.b == 40 && $0.a == 255 }
    )
    _ = try page.evaluate("localStorage.setItem('previous-page', 'state')")
    let next = try browser.newPage()
    try next.goto(address)
    XCTAssertTrue(try next.evaluate("localStorage.getItem('previous-page')").isNull)
  }
}

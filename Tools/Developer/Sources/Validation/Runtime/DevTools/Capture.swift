internal import Foundation
internal import ToolSupport

#if canImport(Darwin)
  internal import CoreGraphics
  internal import ImageIO
#endif

/// Port of `scripts/capture-ui-devtools.swift`: capture the actual window draw
/// list through its renderer's DevTools mirror. Also called in-process by the
/// editor loop.
enum CaptureUI {
  static let usage = "guava-dev devtools capture-ui PORT|@SESSION_FILE OUTPUT.jpg [--settle-ms 0...2000]"

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    let settle = try settleMilliseconds(arguments)
    try capture(endpoint: DevToolsEndpoint.resolve(arguments[0]), destination: URL(fileURLWithPath: arguments[1]), settleMilliseconds: settle)
  }

  static func settleMilliseconds(_ arguments: [String]) throws -> Int {
    if arguments.count == 2 { return 0 }
    guard arguments.count == 4, arguments[2] == "--settle-ms",
          let delay = Int(arguments[3]), (0...2000).contains(delay) else {
      throw ToolError.message("Usage: \(usage)")
    }
    return delay
  }

  static func capture(endpoint: URL, destination: URL, settleMilliseconds: Int = 0) throws {
    #if !canImport(Darwin)
      throw ToolError.message("DevTools capture requires macOS")
    #else
      try AsyncBridge.wait { try await perform(endpoint: endpoint, destination: destination, settleMilliseconds: settleMilliseconds) }
    #endif
  }

  #if canImport(Darwin)
    private static func perform(endpoint: URL, destination: URL, settleMilliseconds: Int) async throws {
      let connection = DevToolsSocket(
        url: endpoint, timeout: 15, maximumMessageSize: 32 * 1024 * 1024)
      defer { connection.close() }

      let hello = try await connection.receiveEnvelope()
      guard hello["type"] as? String == "hello",
        let capabilities = (hello["payload"] as? [String: Any])?["capabilities"] as? [String],
        capabilities.contains("mirror")
      else {
        throw ToolError.message("DevTools mirror is unavailable")
      }
      if settleMilliseconds > 0 { try await Task.sleep(for: .milliseconds(settleMilliseconds)) }
      try await connection.send([
        "type": "mirror.start", "id": 1, "payload": ["fps": 1, "quality": 1],
      ])
      var capture: [String: Any] = [:]
      while capture.isEmpty {
        let envelope = try await connection.receiveEnvelope()
        if envelope["type"] as? String == "mirror.frame" {
          capture = envelope["payload"] as? [String: Any] ?? [:]
        }
      }
      guard let encoded = capture.removeValue(forKey: "jpegBase64") as? String,
        let jpeg = Data(base64Encoded: encoded),
        let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let pixels = image.dataProvider?.data
      else {
        throw ToolError.message("Incomplete mirror image")
      }
      let distinctValues = Set(pixels as Data).count
      guard image.width > 0, image.height > 0, distinctValues > 32 else {
        throw ToolError.message("Blank mirror image")
      }
      try jpeg.write(to: destination)
      capture["distinctByteValues"] = distinctValues
      try await connection.send(["type": "mirror.stop", "id": 2])
      while true {
        if try await connection.receiveEnvelope()["type"] as? String == "mirror.stop.ok" { break }
      }

      let report: [String: Any] = [
        "hello": hello, "capture": capture,
        "source": "selected-renderer offscreen replay of the actual window draw list",
        "captureIncludesCompositor": false,
        "settleMilliseconds": settleMilliseconds,
      ]
      try JSON.write(
        report, to: destination.deletingPathExtension().appendingPathExtension("json"), pretty: true
      )
      Terminal.info("Captured \(image.width)×\(image.height): \(destination.path)")
    }
  #endif
}

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
  static let usage = "guava-dev devtools capture-ui PORT OUTPUT.jpg"

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    guard arguments.count == 2, let port = UInt16(arguments[0]), port > 0 else {
      throw ToolError.message("Usage: \(usage)")
    }
    try capture(port: port, destination: URL(fileURLWithPath: arguments[1]))
  }

  static func capture(port: UInt16, destination: URL) throws {
    #if !canImport(Darwin)
      throw ToolError.message("DevTools capture requires macOS")
    #else
      try AsyncBridge.wait { try await perform(port: port, destination: destination) }
    #endif
  }

  #if canImport(Darwin)
    private static func perform(port: UInt16, destination: URL) async throws {
      guard let endpoint = DevToolsSocket.loopback(port: port, token: true) else {
        throw ToolError.message("Invalid DevTools endpoint")
      }
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
      ]
      try JSON.write(
        report, to: destination.deletingPathExtension().appendingPathExtension("json"), pretty: true
      )
      Terminal.info("Captured \(image.width)×\(image.height): \(destination.path)")
    }
  #endif
}

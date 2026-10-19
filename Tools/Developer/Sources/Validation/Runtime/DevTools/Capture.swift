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
  static let usage = "guava-dev devtools capture-ui PORT|@SESSION_FILE OUTPUT.jpg [--settle-ms 0...2000] [--scale 1...3]"

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    let options = try options(arguments)
    try capture(endpoint: DevToolsEndpoint.resolve(arguments[0]), destination: URL(fileURLWithPath: arguments[1]),
                settleMilliseconds: options.settleMilliseconds, scale: options.scale)
  }

  struct Options: Equatable {
    var settleMilliseconds = 0
    /// Pixels per logical point; 2 inspects hairlines and radii at Retina density.
    var scale: Double = 1
  }

  static func options(_ arguments: [String]) throws -> Options {
    guard arguments.count >= 2 else { throw ToolError.message("Usage: \(usage)") }
    var options = Options(), rest = arguments.dropFirst(2)[...]
    while let flag = rest.popFirst() {
      guard let value = rest.popFirst() else { throw ToolError.message("Usage: \(usage)") }
      switch flag {
      case "--settle-ms":
        guard let delay = Int(value), (0...2000).contains(delay) else { throw ToolError.message("Usage: \(usage)") }
        options.settleMilliseconds = delay
      case "--scale":
        guard let scale = Double(value), scale.isFinite, (1...3).contains(scale) else { throw ToolError.message("Usage: \(usage)") }
        options.scale = scale
      default: throw ToolError.message("Usage: \(usage)")
      }
    }
    return options
  }

  static func capture(endpoint: URL, destination: URL, settleMilliseconds: Int = 0, scale: Double = 1) throws {
    #if !canImport(Darwin)
      throw ToolError.message("DevTools capture requires macOS")
    #else
      try AsyncBridge.wait { try await perform(endpoint: endpoint, destination: destination, settleMilliseconds: settleMilliseconds, scale: scale) }
    #endif
  }

  #if canImport(Darwin)
    private static func perform(endpoint: URL, destination: URL, settleMilliseconds: Int, scale: Double) async throws {
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
        "type": "mirror.start", "id": 1, "payload": ["fps": 1, "quality": 1, "scale": scale],
      ])
      var capture: [String: Any] = [:]
      // Other envelopes keep arriving while the host fails to capture, so
      // bound the wait as a whole rather than per message.
      let deadline = ContinuousClock.now + .seconds(15)
      while capture.isEmpty {
        guard ContinuousClock.now < deadline else {
          throw ToolError.message("No mirror frame within 15 s; the application log reports mirror capture failures")
        }
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

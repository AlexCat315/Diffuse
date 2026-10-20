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
  static let usage = "guava-dev devtools capture-ui PORT|@SESSION_FILE OUTPUT.jpg [--settle-ms 0...2000] [--scale 1...3] [--node NODE_ID | --region X,Y,W,H] (--node crops to the node's visible frame plus 12 pt; --region crops logical points; combine with --scale 2 to inspect type, hairlines and radii close up)"

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    let options = try options(arguments)
    try capture(endpoint: DevToolsEndpoint.resolve(arguments[0]), destination: URL(fileURLWithPath: arguments[1]),
                settleMilliseconds: options.settleMilliseconds, scale: options.scale, crop: options.crop)
  }

  struct Options: Equatable {
    var settleMilliseconds = 0
    /// Pixels per logical point; 2 inspects hairlines and radii at Retina density.
    var scale: Double = 1
    var crop: Crop?
  }

  /// A close-up of part of the window, in logical points.
  enum Crop: Equatable {
    case node(String)
    case region(x: Double, y: Double, width: Double, height: Double)
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
      case "--node":
        guard options.crop == nil, !value.isEmpty, value.allSatisfy(\.isNumber) else { throw ToolError.message("Usage: \(usage)") }
        options.crop = .node(value)
      case "--region":
        let parts = value.split(separator: ",").compactMap { Double($0) }
        guard options.crop == nil, parts.count == 4, parts.allSatisfy(\.isFinite), parts[2] > 0, parts[3] > 0 else {
          throw ToolError.message("Usage: \(usage)")
        }
        options.crop = .region(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
      default: throw ToolError.message("Usage: \(usage)")
      }
    }
    return options
  }

  static func capture(endpoint: URL, destination: URL, settleMilliseconds: Int = 0, scale: Double = 1,
                      crop: Crop? = nil) throws {
    #if !canImport(Darwin)
      throw ToolError.message("DevTools capture requires macOS")
    #else
      try AsyncBridge.wait { try await perform(endpoint: endpoint, destination: destination, settleMilliseconds: settleMilliseconds, scale: scale, crop: crop) }
    #endif
  }

  #if canImport(Darwin)
    private static func perform(endpoint: URL, destination: URL, settleMilliseconds: Int, scale: Double,
                                crop: Crop?) async throws {
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
      let region = try await cropRegion(crop, connection: connection)
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
      // The host may cap the requested scale, so crop with the one it delivered.
      let logicalWidth = (capture["logicalWidth"] as? NSNumber)?.doubleValue ?? 0
      let delivered = logicalWidth > 0 ? Double(image.width) / logicalWidth : scale
      let output = try region.map { try cropped(image, to: $0, scale: delivered) } ?? (jpeg, image.width, image.height)
      try output.0.write(to: destination)
      if let region { capture["cropPoints"] = ["x": region.minX, "y": region.minY, "w": region.width, "h": region.height] }
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
      Terminal.info("Captured \(output.1)×\(output.2): \(destination.path)")
    }

    /// Logical-point rectangle to keep, resolved before the frame is requested.
    private static func cropRegion(_ crop: Crop?, connection: DevToolsSocket) async throws -> CGRect? {
      switch crop {
      case nil: return nil
      case .region(let x, let y, let width, let height): return CGRect(x: x, y: y, width: width, height: height)
      case .node(let id):
        try await connection.send([
          "type": "diagnostics.call", "id": 3,
          "payload": ["name": "query_ui_nodes", "arguments": ["node_id": id, "visible_only": true, "limit": 1]],
        ])
        while true {
          let envelope = try await connection.receiveEnvelope()
          guard envelope["id"] as? Int == 3 else { continue }
          let payload = envelope["payload"] as? [String: Any]
          guard let items = (payload?["data"] as? [String: Any])?["items"] as? [[String: Any]],
            let presentation = items.first?["presentation"] as? [String: Any],
            let frame = presentation["visibleFrame"] as? [String: Double],
            let x = frame["x"], let y = frame["y"], let width = frame["w"], let height = frame["h"],
            width > 0, height > 0
          else {
            throw ToolError.message("Node \(id) has no visible frame; query the current window again")
          }
          // A margin keeps focus rings, shadows and neighbouring alignment in view.
          return CGRect(x: x, y: y, width: width, height: height).insetBy(dx: -12, dy: -12)
        }
      }
    }

    private static func cropped(_ image: CGImage, to region: CGRect, scale: Double) throws -> (Data, Int, Int) {
      let pixels = CGRect(x: region.minX * scale, y: region.minY * scale,
                          width: region.width * scale, height: region.height * scale).integral
        .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
      guard !pixels.isNull, pixels.width >= 1, pixels.height >= 1, let part = image.cropping(to: pixels) else {
        throw ToolError.message("The crop region lies outside the captured window")
      }
      let data = NSMutableData()
      guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else {
        throw ToolError.message("Could not encode the cropped capture")
      }
      CGImageDestinationAddImage(destination, part, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
      guard CGImageDestinationFinalize(destination) else { throw ToolError.message("Could not encode the cropped capture") }
      return (data as Data, part.width, part.height)
    }
  #endif
}

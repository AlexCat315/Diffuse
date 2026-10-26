internal import Foundation
internal import ToolSupport

/// Resize the live main window, as a user dragging its corner would, so
/// layout and resize handling can be exercised without OS automation.
enum ResizeWindow {
  static let usage = "cove-dev devtools resize-window PORT|@SESSION_FILE WIDTH HEIGHT [--capture OUTPUT.jpg] (logical points; the platform may clamp to the screen or the window's minimum size)"

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    guard arguments.count == 3 || (arguments.count == 5 && arguments[3] == "--capture"),
      let width = Double(arguments[1]), let height = Double(arguments[2]),
      (1...16_384).contains(width), (1...16_384).contains(height)
    else { throw ToolError.message("Usage: \(usage)") }
    let endpoint = try DevToolsEndpoint.resolve(arguments[0])
    let capture = arguments.count == 5 ? URL(fileURLWithPath: arguments[4]) : nil

    #if !canImport(Darwin)
      throw ToolError.message("DevTools window control requires macOS")
    #else
      try AsyncBridge.wait {
        let connection = DevToolsSocket(url: endpoint, timeout: 15, maximumMessageSize: 1_048_576)
        defer { connection.close() }
        let hello = try await connection.receive()
        guard hello["type"] as? String == "hello",
          ((hello["payload"] as? [String: Any])?["capabilities"] as? [String])?.contains("window") == true
        else { throw ToolError.message("Host must advertise window") }
        try await connection.send(["type": "window.resize", "id": 1, "payload": ["width": width, "height": height]])
        while true {
          let response = try await connection.receive()
          guard response["id"] as? Int == 1 else { continue }
          guard response["type"] as? String == "window.resize.ok" else {
            throw ToolError.message(JSON.text((response["payload"] as? [String: Any])?["message"] ?? response))
          }
          break
        }
        // Give the host a frame to lay out and render at the new size.
        try await Task.sleep(for: .milliseconds(250))
        Terminal.info("Requested a \(Int(width))×\(Int(height)) window; query or capture the UI to verify layout.")
      }
      if let capture { try CaptureUI.capture(endpoint: endpoint, destination: capture) }
    #endif
  }
}

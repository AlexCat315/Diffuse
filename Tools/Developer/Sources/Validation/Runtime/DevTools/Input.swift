internal import Foundation
internal import ToolSupport

/// Port of `scripts/input-ui-devtools.swift`: drive the host's input dispatcher
/// through DevTools, without OS automation.
enum InputUI {
  static let usage = "guava-dev devtools input-ui PORT --click-node NODE_ID | --input JSON_OR_@FILE"

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    guard arguments.count == 3, let port = UInt16(arguments[0]), port > 0,
      ["--click-node", "--input"].contains(arguments[1])
    else {
      throw ToolError.message("Usage: \(usage)")
    }
    let target = arguments[1]
    let raw = arguments[2]

    #if !canImport(Darwin)
      throw ToolError.message("DevTools input requires macOS")
    #else
      try AsyncBridge.wait {
        guard let endpoint = DevToolsSocket.loopback(port: port, token: true) else {
          throw ToolError.message("Invalid DevTools endpoint")
        }
        let connection = DevToolsSocket(
          url: endpoint, timeout: 15, maximumMessageSize: 32 * 1024 * 1024)
        defer { connection.close() }

        var sequence = 0
        func request(_ type: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
          sequence += 1
          let identifier = sequence
          try await connection.send(["type": type, "id": identifier, "payload": payload])
          while true {
            let response = try await connection.receive()
            guard response["id"] as? Int == identifier else { continue }
            guard response["type"] as? String == type + ".ok" else {
              throw ToolError.message(JSON.text(response["payload"] ?? [:]))
            }
            return response["payload"] as? [String: Any] ?? [:]
          }
        }

        let hello = try await connection.receive()
        let capabilities = (hello["payload"] as? [String: Any])?["capabilities"] as? [String] ?? []
        guard hello["type"] as? String == "hello", capabilities.contains("mirror"),
          capabilities.contains("diagnostics")
        else {
          throw ToolError.message("Host must advertise mirror and diagnostics")
        }

        let events: [[String: Any]]
        if target == "--click-node" {
          events = try await clickEvents(node: raw, request: request)
        } else {
          events = try loadEvents(raw)
        }

        _ = try await request("mirror.start", ["fps": 1, "quality": 0.5])
        for event in events { _ = try await request("mirror.input", event) }
        // A host-inbox read keeps the connection alive until the preceding
        // input deliveries have reached the host.
        _ = try await request(
          "diagnostics.call", ["name": "get_diagnostics", "arguments": ["limit": 1]])
        _ = try await request("mirror.stop")
        Terminal.info(
          "Delivered \(events.count) input events through DevTools; query or capture the resulting UI to verify behavior."
        )
      }
    #endif
  }

  /// Pointer events centred on the node's visible, input-enabled hit region.
  private static func clickEvents(
    node: String,
    request: (String, [String: Any]) async throws -> [String: Any]
  ) async throws -> [[String: Any]] {
    let result = try await request(
      "diagnostics.call",
      [
        "name": "query_ui_nodes",
        "arguments": [
          "node_id": node, "visible_only": true, "input_enabled_only": true, "limit": 1,
        ],
      ])
    guard let items = (result["data"] as? [String: Any])?["items"] as? [[String: Any]],
      items.count == 1,
      let presentation = items[0]["presentation"] as? [String: Any],
      let frame = presentation["visibleFrame"] as? [String: Double],
      let x = frame["x"], let y = frame["y"], let width = frame["w"], let height = frame["h"],
      [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0
    else {
      throw ToolError.message(
        "Node has no visible input-enabled hit region; query the current window again")
    }
    return ["pointerMove", "pointerDown", "pointerUp"].map {
      ["kind": $0, "x": x + width / 2, "y": y + height / 2, "button": 0, "clickCount": 1]
    }
  }

  /// Validates an inline or `@FILE` array of 1–256 input events.
  private static func loadEvents(_ raw: String) throws -> [[String: Any]] {
    let bytes =
      try raw.hasPrefix("@")
      ? Fs.read(URL(fileURLWithPath: String(raw.dropFirst())))
      : Data(raw.utf8)
    guard bytes.count <= 262_144,
      let input = (try? JSON.parse(bytes)) as? [[String: Any]], (1...256).contains(input.count)
    else {
      throw ToolError.message("Input must be a JSON array of 1–256 events, at most 256 KiB")
    }
    let kinds = ["pointerMove", "pointerDown", "pointerUp", "wheel", "keyDown", "keyUp", "text"]
    guard
      input.allSatisfy({ event in
        guard let kind = event["kind"] as? String, kinds.contains(kind) else { return false }
        return event.values.allSatisfy { value in
          if let number = value as? NSNumber { return number.doubleValue.isFinite }
          if let text = value as? String { return text.utf8.count <= 16_384 }
          return value is [String: Any]
        }
      })
    else {
      throw ToolError.message("Input contains an unsupported kind, value or oversized string")
    }
    return input
  }
}

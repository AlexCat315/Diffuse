internal import Foundation
internal import ToolSupport

/// Port of `scripts/query-ui-devtools.swift`: invoke the runtime's validated,
/// read-only AI tools against the actual window.
enum QueryUI {
  static let usage = "guava-dev validate query-ui PORT --list | TOOL [JSON | @FILE]"

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    guard arguments.count >= 2, arguments.count <= 3, let port = UInt16(arguments[0]), port > 0
    else {
      throw ToolError.message("Usage: \(usage)")
    }
    let listing = arguments[1] == "--list"
    var payload: [String: Any] = [:]
    if !listing {
      let raw = arguments.count == 3 ? arguments[2] : "{}"
      let input =
        try raw.hasPrefix("@")
        ? Fs.read(URL(fileURLWithPath: String(raw.dropFirst())))
        : Data(raw.utf8)
      guard input.count <= 262_144, let object = (try? JSON.parse(input)) as? [String: Any] else {
        throw ToolError.message("Tool arguments must be a JSON object of at most 256 KiB")
      }
      payload = ["name": arguments[1], "arguments": object]
    }

    #if !canImport(Darwin)
      throw ToolError.message("DevTools queries require macOS")
    #else
      try AsyncBridge.wait {
        guard let endpoint = DevToolsSocket.loopback(port: port, token: true) else {
          throw ToolError.message("Invalid DevTools endpoint")
        }
        let connection = DevToolsSocket(url: endpoint, timeout: 10, maximumMessageSize: 1_048_576)
        defer { connection.close() }

        let hello = try await connection.receive()
        guard hello["type"] as? String == "hello",
          let capabilities = (hello["payload"] as? [String: Any])?["capabilities"] as? [String],
          capabilities.contains("diagnostics")
        else {
          throw ToolError.message("Host does not advertise diagnostic queries")
        }
        let type = listing ? "diagnostics.tools" : "diagnostics.call"
        try await connection.send(["type": type, "id": 1, "payload": payload])
        while true {
          let response = try await connection.receive()
          guard response["id"] as? Int == 1 else { continue }
          if response["type"] as? String == type + ".err" {
            throw ToolError.message(JSON.text(response["payload"] ?? [:]))
          }
          guard response["type"] as? String == type + ".ok", let value = response["payload"] else {
            throw ToolError.message("Unexpected diagnostic response")
          }
          Terminal.info(JSON.pretty(value))
          break
        }
      }
    #endif
  }
}

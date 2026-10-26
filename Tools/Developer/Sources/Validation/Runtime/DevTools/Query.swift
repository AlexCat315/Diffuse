internal import Foundation
internal import ToolSupport

/// Port of `scripts/query-ui-devtools.swift`: invoke the runtime's validated,
/// read-only AI tools against the actual window.
enum QueryUI {
  static let usage = "cove-dev devtools query-ui PORT|@SESSION_FILE --list | TOOL [JSON | @FILE]"

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    guard arguments.count >= 2, arguments.count <= 3
    else {
      throw ToolError.message("Usage: \(usage)")
    }
    let endpoint = try DevToolsEndpoint.resolve(arguments[0])
    let listing = arguments[1] == "--list"
    let raw = arguments.count == 3 ? arguments[2] : "{}"
    let input = try raw.hasPrefix("@") ? Fs.read(URL(fileURLWithPath: String(raw.dropFirst()))) : Data(raw.utf8)
    guard input.count <= 262_144 else { throw ToolError.message("Tool arguments must be a JSON object of at most 256 KiB") }

    #if !canImport(Darwin)
      throw ToolError.message("DevTools queries require macOS")
    #else
      try AsyncBridge.wait {
        var payload: [String: Any] = [:]
        if !listing {
          guard let object = (try? JSON.parse(input)) as? [String: Any] else {
            throw ToolError.message("Tool arguments must be a JSON object of at most 256 KiB")
          }
          payload = ["name": arguments[1], "arguments": object]
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
          Terminal.info(render(value, compact: (payload["arguments"] as? [String: Any])?["compact"] as? Bool == true))
          break
        }
      }
    #endif
  }
}

extension QueryUI {
  /// Compact node queries print one JSON object per line, then a paging
  /// summary, so an agent reads a result in a few lines; everything else is
  /// pretty-printed.
  static func render(_ value: Any, compact: Bool) -> String {
    guard compact, let data = (value as? [String: Any])?["data"] as? [String: Any],
          let items = data["items"] as? [Any] else { return JSON.pretty(value) }
    var lines = items.map { JSON.text($0) }
    let total = data["total"].map { JSON.text($0) } ?? String(items.count)
    let next = data["nextOffset"].flatMap { $0 is NSNull ? nil : ", next offset \(JSON.text($0))" } ?? ""
    lines.append("\(items.count) of \(total) nodes\(next)")
    return lines.joined(separator: "\n")
  }
}

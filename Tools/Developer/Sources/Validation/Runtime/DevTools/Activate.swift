internal import Foundation
internal import ToolSupport

/// Run one accessibility action on a live node, as an assistive client would.
/// It needs no visible geometry, so offscreen or virtualized items can be
/// reached; query the result afterwards like any other input.
enum ActivateUI {
  static let usage = "guava-dev devtools activate-ui PORT|@SESSION_FILE NODE_ID [activate|increment|decrement|reveal] (reveal scrolls the node into view without activating it)"

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    guard (2...3).contains(arguments.count) else { throw ToolError.message("Usage: \(usage)") }
    let action = arguments.count == 3 ? arguments[2] : "activate"
    guard ["activate", "increment", "decrement", "reveal"].contains(action) else { throw ToolError.message("Usage: \(usage)") }
    let endpoint = try DevToolsEndpoint.resolve(arguments[0])
    let node = arguments[1]

    #if !canImport(Darwin)
      throw ToolError.message("DevTools actions require macOS")
    #else
      try AsyncBridge.wait {
        let connection = DevToolsSocket(url: endpoint, timeout: 15, maximumMessageSize: 1_048_576)
        defer { connection.close() }
        let hello = try await connection.receive()
        guard hello["type"] as? String == "hello",
          ((hello["payload"] as? [String: Any])?["capabilities"] as? [String])?.contains("mirror") == true
        else { throw ToolError.message("Host must advertise mirror") }
        func request(_ type: String, _ id: Int, _ payload: [String: Any] = [:]) async throws {
          try await connection.send(["type": type, "id": id, "payload": payload])
          while true {
            let response = try await connection.receive()
            guard response["id"] as? Int == id else { continue }
            guard response["type"] as? String == type + ".ok" else {
              throw ToolError.message(JSON.text((response["payload"] as? [String: Any])?["message"] ?? response))
            }
            return
          }
        }
        try await request("mirror.start", 1, ["fps": 1, "quality": 0.5])
        try await request("mirror.activate", 2, ["node_id": node, "action": action])
        try await request("mirror.stop", 3)
        Terminal.info("Performed \(action) on node \(node); query the resulting UI to verify behavior.")
      }
    #endif
  }
}

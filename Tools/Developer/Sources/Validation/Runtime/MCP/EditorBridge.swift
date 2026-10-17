internal import Foundation
internal import ToolSupport

/// Port of `validate_bridge_connections`: two concurrent loopback clients, a
/// fragmented frame, pipelined frames and malformed-request recovery against
/// the editor's JSON TCP bridge.
enum EditorBridge {
  static func validateConnections(port: UInt16) throws {
    let request =
      try JSON.data([
        "action": "project_tool", "tool_name": "get_project_info", "arguments": [String: Any](),
      ]) + Data([0x0A])
    let first = try TCPClient(host: "127.0.0.1", port: port, timeout: 5)
    let second = try TCPClient(host: "127.0.0.1", port: port, timeout: 5)
    defer {
      first.close()
      second.close()
    }

    try first.send(request.prefix(13))
    try second.send(request)
    try ok(try second.readLine())
    try first.send(Data(request.dropFirst(13)) + request)
    try ok(try first.readLine())
    try ok(try first.readLine())
    try second.send(Data("{malformed}\n".utf8) + request)
    try notOK(try second.readLine())
    try ok(try second.readLine())

    Terminal.info(
      "Editor bridge passed: simultaneous clients, fragmented and pipelined frames, malformed request recovery"
    )
  }

  private static func ok(_ line: Data) throws {
    guard try replyOK(line) else { throw ToolError.message("Bridge rejected a valid request") }
  }

  private static func notOK(_ line: Data) throws {
    guard try replyOK(line) == false else {
      throw ToolError.message("Bridge accepted a malformed request")
    }
  }

  private static func replyOK(_ line: Data) throws -> Bool {
    let object = try JSON.parseObject(line)
    guard let value = JSON.boolean(object["ok"]) else {
      throw ToolError.message("Bridge reply without an ok field: \(JSON.text(object))")
    }
    return value
  }
}

internal import Foundation
internal import ToolSupport

/// Shared by AI clients and the CLI session verifier. Session credentials stay
/// inside the connection URL and never need to be printed or copied into a shell.
enum DevToolsEndpoint {
  static func resolve(_ target: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
    if let port = UInt16(target), port > 0 {
      var url = URLComponents(); url.scheme = "ws"; url.host = "127.0.0.1"; url.port = Int(port); url.path = "/"
      if let token = environment["GUAVA_DEVTOOLS_TOKEN"], !token.isEmpty { url.queryItems = [URLQueryItem(name: "token", value: token)] }
      return url.url!
    }
    guard target.hasPrefix("@"), target.count > 1 else { throw ToolError.message("Endpoint must be a port or @path/to/session.json (runtime.json is also supported)") }
    let bytes = try Fs.read(URL(fileURLWithPath: String(target.dropFirst())))
    guard bytes.count <= 262_144 else { throw ToolError.message("DevTools session file exceeds 256 KiB") }
    return try session(JSON.parseObject(bytes))
  }

  static func session(_ session: [String: Any]) throws -> URL {
    let runtime = JSON.dict(session["runtime"]) ?? session
    guard let text = JSON.string(runtime["endpoint"]), var url = URLComponents(string: text) else {
      throw ToolError.message("DevTools session has no runtime endpoint")
    }
    if let device = JSON.dict(session["device"]) {
      guard let port = JSON.number(device["forwardedPort"]), port.rounded() == port, (1...65535).contains(port) else {
        throw ToolError.message("DevTools session has an invalid forwarded port")
      }
      url.port = Int(port)
    }
    guard url.scheme == "ws", ["127.0.0.1", "localhost", "::1", "[::1]"].contains(url.host ?? ""),
          let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
          let endpoint = url.url else { throw ToolError.message("DevTools session must contain a loopback WebSocket endpoint with a valid port") }
    return endpoint
  }
}

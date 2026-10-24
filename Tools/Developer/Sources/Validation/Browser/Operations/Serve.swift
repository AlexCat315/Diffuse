internal import Foundation
private import ToolSupport

/// `serve` — the static file server `package.json`'s `serve` script runs with
/// `python3 -m http.server 8080 --bind 127.0.0.1 --directory dist`. The default
/// port and directory match that command exactly.
enum ServeOperation {
  static func run(_ arguments: [String]) throws {
    var parser = FlagParser(arguments, valued: ["--port", "--dist"])
    try parser.parse()
    if parser.flags.contains("--help") {
      Terminal.info(Browser.usage)
      return
    }
    if let unexpected = parser.positionals.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }
    let port: Int
    if let raw = parser.values["--port"] {
      guard let value = Int(raw) else {
        throw ToolError.message("argument --port: invalid int value: '\(raw)'")
      }
      port = value
    } else {
      port = 8080
    }
    let root = Browser.sdkRoot.appendingPathComponent("Browser")
    let dist = parser.values["--dist"] ?? "dist"
    let directory =
      (dist as NSString).isAbsolutePath
      ? URL(fileURLWithPath: dist).standardizedFileURL
      : root.appendingPathComponent(dist).standardizedFileURL
    let server = try staticServer(directory: directory, port: port)
    server.start()
    defer { server.stop() }
    Terminal.info(
      "Serving HTTP on 127.0.0.1 port \(server.port) (http://127.0.0.1:\(server.port)/) ...")
    flushOutput()
    while true { Thread.sleep(forTimeInterval: 1) }
  }
}

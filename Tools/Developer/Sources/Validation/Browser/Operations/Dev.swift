internal import Foundation
private import ToolSupport

/// `dev` — local Swift/Wasm development server with complete-build reloads and
/// Server-Sent Events. Replaces `CoveUI/Browser/dev.py`.
enum DevOperation {
  static func run(_ arguments: [String]) throws {
    var parser = FlagParser(arguments, valued: ["--port"])
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
    try dev(port: port)
  }

  static func dev(port: Int) throws {
    let root = Browser.sdkRoot.appendingPathComponent("Browser")
    let outcome = try build(root: root)
    guard let revision = outcome.revision else { throw ToolError.message("Initial build failed") }
    let server = try DevServer(port: port, revision: revision, root: root)
    server.start()
    defer { server.stop() }
    Terminal.info("CoveUI dev server: http://127.0.0.1:\(server.port)")
    flushOutput()
    let watcher = Thread { watch(root: root, state: server.state) }
    watcher.stackSize = 1 << 20
    watcher.start()
    while true { Thread.sleep(forTimeInterval: 1) }
  }

  /// The rebuilt output for one complete build, or the tail of its failure.
  struct BuildOutcome {
    var revision: String?
    var error: String?
  }

  /// Runs one complete `build.sh` into a fresh revision directory.
  static func build(root: URL) throws -> BuildOutcome {
    let revision = String(Int(Date().timeIntervalSince1970 * 1_000_000_000))
    let destination = root.appendingPathComponent(".dev-builds").appendingPathComponent(revision)
    var environment = ProcessInfo.processInfo.environment
    environment["COVE_WASM_OUTPUT"] = destination.path
    let result = try capture(
      try Shell.require("bash"), ["build.sh"], directory: root, environment: environment)
    Terminal.info(result.output)
    flushOutput()
    guard result.status == 0 else {
      try? Fs.remove(destination)
      return BuildOutcome(revision: nil, error: String(result.output.suffix(6000)))
    }
    try Fs.write("{\"enabled\":true}", to: destination.appendingPathComponent("dev-mode.json"))
    return BuildOutcome(revision: revision, error: nil)
  }

  /// Watches the source tree and rebuilds on any change.
  static func watch(root: URL, state: DevState) {
    var previous = fingerprint(root: root)
    while true {
      Thread.sleep(forTimeInterval: 0.3)
      let current = fingerprint(root: root)
      if current == previous { continue }
      Thread.sleep(forTimeInterval: 0.3)
      previous = fingerprint(root: root)
      state.publish(.object(["type": .string("building")]))
      do {
        let outcome = try build(root: root)
        if let revision = outcome.revision {
          state.revision.value = revision
          state.publish(.object(["type": .string("ready")]))
        } else {
          state.publish(
            .object([
              "type": .string("error"),
              "message": .string(outcome.error ?? ""),
            ]))
        }
      } catch {
        state.publish(
          .object([
            "type": .string("error"),
            "message": .string(String(describing: error)),
          ]))
      }
    }
  }

  /// One watched file's change-detecting summary.
  struct FingerprintEntry: Equatable {
    var path: String
    var modified: Int64
    var size: Int64
  }

  /// A change-detecting summary of every watched source file.
  static func fingerprint(root: URL) -> [FingerprintEntry] {
    let repositoryRoot = Repository.root
    let watch = [
      root.appendingPathComponent("Sources"),
      root.appendingPathComponent("web"),
      root.deletingLastPathComponent().appendingPathComponent("Portable/Sources"),
      root.deletingLastPathComponent().appendingPathComponent("Text/Sources"),
      root.deletingLastPathComponent().appendingPathComponent("Text/Fonts"),
      root.deletingLastPathComponent().appendingPathComponent("Text/Package.swift"),
      repositoryRoot.appendingPathComponent(
        "Tools/Developer/Sources/Validation/Browser/Operations/BuildFonts.swift"),
      root.deletingLastPathComponent().appendingPathComponent("DevTools"),
      Browser.sdkRoot.appendingPathComponent("PlatformCore"),
      root.appendingPathComponent("Package.swift"),
      root.deletingLastPathComponent().appendingPathComponent("Portable/Package.swift"),
      root.appendingPathComponent("build.sh"),
    ]
    var entries: [FingerprintEntry] = []
    for source in watch {
      var isDirectory: ObjCBool = false
      let exists = FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory)
      let files = exists && isDirectory.boolValue ? ((try? Fs.files(in: source)) ?? []) : [source]
      for file in files {
        let relative = Fs.relative(file, to: repositoryRoot)
        if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
        guard let info = fileSummary(file) else { continue }
        entries.append(FingerprintEntry(path: file.path, modified: info.mtime, size: info.size))
      }
    }
    return entries.sorted { $0.path < $1.path }
  }

  private static func fileSummary(_ url: URL) -> (mtime: Int64, size: Int64)? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
      return nil
    }
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    return (Int64(modified * 1_000_000_000), size)
  }
}

/// Shared development-server state: the current revision and the connected
/// `EventSource` listeners.
final class DevState: @unchecked Sendable {
  let revision: Locked<String>
  let listeners = Locked<[SSEListener]>([])

  init(revision: String) { self.revision = Locked(revision) }

  func publish(_ event: JSON) {
    for listener in listeners.value { listener.enqueue(event) }
  }
}

/// One `EventSource` connection with a bounded queue, matching `dev.py`'s
/// `queue.Queue(maxsize=8)` where a full listener drops the event.
final class SSEListener: @unchecked Sendable {
  private let condition = NSCondition()
  private var queue: [JSON] = []

  func enqueue(_ event: JSON) {
    condition.lock()
    defer { condition.unlock() }
    guard queue.count < 8 else { return }
    queue.append(event)
    condition.signal()
  }

  func dequeue(timeout: TimeInterval) -> JSON? {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date(timeIntervalSinceNow: timeout)
    while queue.isEmpty {
      if !condition.wait(until: deadline) { return nil }
    }
    return queue.removeFirst()
  }
}

/// The development server: a static file server over `.dev-builds` that redirects
/// `/` to the latest revision and streams build events at `/__cove_events`.
final class DevServer: @unchecked Sendable {
  let server: HTTPServer
  let state: DevState

  init(port: Int, revision: String, root: URL) throws {
    let state = DevState(revision: revision)
    self.state = state
    let builds = root.appendingPathComponent(".dev-builds")
    self.server = try HTTPServer(port: port) { request, response in
      DevServer.route(request, response, state: state, builds: builds)
    }
  }

  var port: Int { server.port }
  func start() { server.start() }
  func stop() { server.stop() }

  private static func route(
    _ request: HTTPRequest, _ response: HTTPResponse,
    state: DevState, builds: URL
  ) {
    let path = request.rawPath
    if path == "/__cove_events" {
      serveEvents(response, state: state)
      return
    }
    if path == "/" {
      var location = "/build/" + state.revision.value + "/"
      if !request.query.isEmpty { location += "?" + request.query }
      response.send(
        status: 302, headers: ["Location": location, "Cache-Control": "no-store"], body: Data())
      return
    }
    guard path.hasPrefix("/build/") else {
      response.sendError(404, "File not found")
      return
    }
    let stripped = String(request.target.dropFirst("/build".count))
    guard
      let rewritten = HTTPRequest.parse(
        head: Data("GET \(stripped) HTTP/1.0\r\n\r\n".utf8), body: Data())
    else {
      response.sendError(400, "Bad request")
      return
    }
    StaticFiles.respond(rewritten, response, directory: builds)
  }

  private static func serveEvents(_ response: HTTPResponse, state: DevState) {
    let listener = SSEListener()
    state.listeners.mutate { $0.append(listener) }
    defer { state.listeners.mutate { $0.removeAll { $0 === listener } } }
    response.stream(headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-store"]) {
      stream in
      guard stream.write(": connected\n\n") else { return }
      while true {
        if let event = listener.dequeue(timeout: 15) {
          if !stream.write("data: " + event.compactText + "\n\n") { return }
        } else if !stream.write(": keepalive\n\n") {
          return
        }
      }
    }
  }
}

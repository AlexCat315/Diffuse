internal import Foundation
internal import ToolSupport

/// Port of `scripts/verify-development-session.mjs`: run against an already
/// launched CLI session and prove the DevTools endpoint rejects unauthenticated
/// clients while serving one real session per platform.
enum DevelopmentSession {
  static let usage = "cove-dev devtools session PROJECT mac|android"

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    guard arguments.count >= 2 else { throw ToolError.message("Usage: \(usage)") }
    let project = URL(fileURLWithPath: arguments[0]).standardizedFileURL
    let platform = arguments[1]
    guard ["mac", "android"].contains(platform) else { throw ToolError.message("Usage: \(usage)") }
    try verify(project: project, platform: platform)
  }

  private static func verify(project: URL, platform: String) throws {
    let folder = project.appendingPathComponent(".build/devtools")
    let entries: [URL]
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: [.isDirectoryKey])
    } catch {
      throw ToolError.message("No DevTools sessions under \(folder.path)")
    }

    var sessions: [[String: Any]] = []
    for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
        continue
      }
      let file = entry.appendingPathComponent("session.json")
      guard let data = try? Data(contentsOf: file),
        let object = (try? JSON.parse(data)) as? [String: Any]
      else { continue }
      sessions.append(object)
    }
    let matching = sessions.filter { $0["platform"] as? String == platform }
    guard matching.count == 1 else {
      throw ToolError.message("Expected exactly one session for this platform")
    }
    let session = matching[0]
    let runtime = try JSON.object(session["runtime"], "runtime")
    let authenticated = try DevToolsEndpoint.session(session)
    let endpoint = URLComponents(url: authenticated, resolvingAgainstBaseURL: false)!
    guard let pid = JSON.int(runtime["pid"]), pid > 0, let id = JSON.string(runtime["id"]), !id.isEmpty else {
      throw ToolError.message("Session must identify its runtime process and session")
    }

    #if !canImport(Darwin)
      throw ToolError.message("Development session verification requires macOS")
    #else
      try AsyncBridge.wait {
        try await check(
          authenticated: authenticated, endpoint: endpoint, runtimePID: pid, sessionID: id, platform: platform)
      }
    #endif
  }

  #if canImport(Darwin)
    private static func check(
      authenticated: URL, endpoint: URLComponents,
      runtimePID: Int, sessionID: String, platform: String
    ) async throws {
      var anonymous = endpoint
      anonymous.query = nil
      guard let anonymousURL = anonymous.url else {
        throw ToolError.message("Session endpoint is invalid")
      }
      try await expectRejection(anonymousURL)

      var wrong = endpoint
      var items = (wrong.queryItems ?? []).filter { $0.name != "token" }
      items.append(URLQueryItem(name: "token", value: "wrong"))
      wrong.queryItems = items
      guard let wrongURL = wrong.url else { throw ToolError.message("Session endpoint is invalid") }
      try await expectRejection(wrongURL)

      let connection = DevToolsSocket(
        url: authenticated, timeout: nil, maximumMessageSize: 32 * 1024 * 1024)
      defer { connection.close() }
      let hello = try await connection.receive(timeout: 5)
      guard hello["type"] as? String == "hello",
        let helloPayload = hello["payload"] as? [String: Any]
      else {
        throw ToolError.message("No hello")
      }
      let host = try JSON.object(helloPayload["host"], "host")
      try Check.require(
        JSON.int(host["pid"]) == runtimePID,
        "The session belongs to another process")
      let capabilities = JSON.strings(helloPayload["capabilities"]) ?? []
      for capability in [
        "log", "tree", "select", "inspect", "style", "source", "recomposition", "timeline",
        "state.observe",
      ] {
        try Check.require(capabilities.contains(capability), "Missing capability \(capability)")
      }

      var identifier = 0
      func request(_ type: String, _ payload: [String: Any] = [:]) async throws -> [String: Any] {
        identifier += 1
        let current = identifier
        try await connection.send(["type": type, "id": current, "payload": payload])
        connection.armTimeout(5)
        do {
          while true {
            let message = try await connection.receive()
            if JSON.int(message["id"]) == current { return message }
          }
        } catch {
          if connection.hasExpired { throw ToolError.message("Timed out waiting for \(type) response") }
          throw error
        }
      }

      let logs = try await request("log.subscribe")
      guard logs["type"] as? String == "log.snapshot" else {
        throw ToolError.message("Unexpected log reply")
      }
      let logPayload = try JSON.object(logs["payload"], "log payload")
      let records = try JSON.objects(logPayload["records"] ?? [Any](), "records")
      try Check.require(!records.isEmpty, "Startup logs were not replayed")
      for record in records {
        let process = JSON.dict(record["process"])
        let location = JSON.dict(record["location"])
        try Check.require(
          JSON.int(record["sequence"]).map { $0 > 0 } == true
            && !(process?["runID"] as? String ?? "").isEmpty
            && !(location?["file"] as? String ?? "").isEmpty,
          "Incomplete log record")
      }
      try Check.require(
        records.contains { $0["label"] as? String == "com.cove.engine.rhi" },
        "Engine logs did not join the application journal")
      try Check.require(
        (try await request("log.unsubscribe"))["type"] as? String == "log.unsubscribe.ok",
        "log.unsubscribe failed")

      let tree = try await request("tree.subscribe")
      guard tree["type"] as? String == "tree.snapshot",
        let root = (tree["payload"] as? [String: Any])?["root"] as? [String: Any]
      else {
        throw ToolError.message("Empty scene tree")
      }
      var identifiers: [Any] = []
      func visit(_ node: [String: Any]) {
        identifiers.append(node["elementID"] ?? node["id"] ?? NSNull())
        for child in JSON.objects(node["children"]) ?? [] { visit(child) }
      }
      visit(root)
      try Check.require(identifiers.count > 5, "Expected real application nodes")
      try Check.require(
        (try await request("select.node", ["id": identifiers.last ?? NSNull()]))["type"] as? String
          == "select.node.ok",
        "select.node failed")
      try Check.require(
        (try await request("select.clear"))["type"] as? String == "select.clear.ok",
        "select.clear failed")
      try Check.require(
        (try await request("state.list"))["type"] as? String == "state.list.ok", "state.list failed"
      )
      try Check.require(
        (try await request("timeline.subscribe"))["type"] as? String == "timeline.events",
        "timeline.subscribe failed")

      var styled = false
      for id in identifiers {
        let reply = try await request(
          "inspect.style.set",
          [
            "id": id,
            "properties": ["padding": ["top": 3, "right": 3, "bottom": 3, "left": 3]],
          ])
        if reply["type"] as? String == "inspect.style.set.ok" {
          styled = true
          break
        }
        try Check.equal(
          (reply["payload"] as? [String: Any])?["code"] as? String, "unsupported", JSON.text(reply))
      }
      try Check.require(styled, "Expected an editable layout node")
      try Check.require(
        (try await request("inspect.style.undo"))["type"] as? String == "inspect.style.undo.ok",
        "inspect.style.undo failed")
      try Check.require(
        (try await request("inspect.style.clearAll"))["type"] as? String
          == "inspect.style.clearAll.ok", "inspect.style.clearAll failed")
      try Check.require(
        (try await request("timeline.unsubscribe"))["type"] as? String == "timeline.unsubscribe.ok",
        "timeline.unsubscribe failed")
      try Check.require(
        (try await request("tree.unsubscribe"))["type"] as? String == "tree.unsubscribe.ok",
        "tree.unsubscribe failed")

      let summary: [String: Any] = [
        "platform": platform, "session": sessionID,
        "nodes": identifiers.count, "replayedLogs": records.count,
        "runID": (records[0]["process"] as? [String: Any])?["runID"] ?? NSNull(),
        "authenticated": true, "capabilities": capabilities,
      ]
      Terminal.info(JSON.pretty(summary))
    }

    /// Connects and requires the handshake to fail; any message means the host
    /// accepted an unauthenticated client.
    private static func expectRejection(_ url: URL) async throws {
      let connection = DevToolsSocket(url: url, timeout: 5, maximumMessageSize: 1_048_576)
      defer { connection.close() }
      do {
        _ = try await connection.receive()
      } catch {
        if connection.hasExpired { throw ToolError.message("Unauthenticated handshake timed out") }
        return
      }
      throw ToolError.message("Unauthenticated client connected")
    }
  #endif
}

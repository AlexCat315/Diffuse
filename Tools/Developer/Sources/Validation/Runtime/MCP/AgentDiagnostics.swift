internal import Foundation
internal import ToolSupport

/// Port of `scripts/validate-agent-diagnostics.py`: exercise real stdio MCP
/// through the portable TCP transport into the headless editor's tools.
enum AgentDiagnostics {
  static let usage = """
    guava-dev validate agent-diagnostics

    Launches the headless editor in a temporary project and drives GuavaMCP
    over stdio against it. Needs a built EditorApp and GuavaMCP.
    """

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    if let unexpected = arguments.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }

    let port = try FreePort.reserve()
    var environment = ProcessInfo.processInfo.environment
    environment["GUAVA_MCP_PORT"] = String(port)

    let directory = try Temp.directory(prefix: "guava-agent-diagnostics-")
    defer { try? Fs.remove(directory) }
    let log = directory.appendingPathComponent("editor.log")
    let logHandle = try openForWriting(log)

    let editor = try BuildProducts.executable(package: "Editor", name: "EditorApp")
    let child = try ChildProcess(
      editor, ["--mcp-headless", "--project-dir", directory.path],
      environment: environment, stdout: .file(logHandle), stderr: .file(logHandle))
    var mcp: ChildProcess?
    defer {
      for process in [mcp, child].compactMap({ $0 }) where process.isRunning {
        process.terminate()
        if process.wait(timeout: 5) == nil {
          process.kill()
          _ = process.wait(timeout: 5)
        }
      }
    }

    try waitForTransport(child: child, port: port, log: log)
    mcp = try ChildProcess(
      try BuildProducts.executable(package: "GuavaMcp", name: "GuavaMCP"),
      environment: environment, stdin: .pipe, stdout: .pipe, stderr: .file(logHandle))
    try inspect(mcp!)
    Terminal.info(
      "Agent diagnostics passed: stdio MCP, TCP bridge, domain report, shared skills, and unavailable UI"
    )
  }

  private static func waitForTransport(child: ChildProcess, port: UInt16, log: URL) throws {
    let deadline = Date().addingTimeInterval(20)
    while true {
      if !child.isRunning { throw ToolError.message(try readText(log)) }
      if let probe = try? TCPClient(host: "127.0.0.1", port: port, timeout: 0.2) {
        probe.close()
        return
      }
      guard Date() < deadline else {
        throw ToolError.message("Editor transport did not become ready")
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
  }

  private static func inspect(_ mcp: ChildProcess) throws {
    var identifier = 0
    @discardableResult
    func request(_ method: String, _ params: [String: Any]? = nil) throws -> [String: Any] {
      identifier += 1
      var message: [String: Any] = ["jsonrpc": "2.0", "id": identifier, "method": method]
      if let params { message["params"] = params }
      try mcp.sendLine(message)
      while true {
        guard let response = try mcp.readLine(timeout: 10) else {
          throw ToolError.message("MCP request timed out: \(method)")
        }
        guard response["id"] as? Int == identifier else { continue }
        guard response["error"] == nil else { throw ToolError.message(JSON.text(response)) }
        return try JSON.object(response["result"], "result")
      }
    }
    func tool(_ name: String, _ arguments: [String: Any]? = nil) throws -> [String: Any] {
      try request("tools/call", ["name": name, "arguments": arguments ?? [String: Any]()])
    }

    try request("initialize", ["protocolVersion": "2025-11-25"])
    let definitions = try JSON.objects(try request("tools/list")["tools"], "tools")
    try Check.require(
      definitions.contains { $0["name"] as? String == "query_ui_nodes" },
      "GuavaMCP is missing query_ui_nodes")

    let report = try tool("get_diagnostics")
    try Check.equal(try JSON.boolean(report["isError"], "isError"), false, JSON.text(report))
    let structured = try JSON.object(report["structuredContent"], "structuredContent")
    try Check.equal(
      try JSON.boolean(structured["uiAvailable"], "uiAvailable"), false, JSON.text(report))
    try Check.equal(
      try JSON.int(structured["frameSampleCount"], "frameSampleCount"), 0, JSON.text(report))
    try Check.require(JSON.list(structured["issues"]) != nil, JSON.text(report))

    let skills = try tool("list_skills")
    let skillsData = try JSON.array(
      try JSON.object(skills["structuredContent"], "structuredContent")["data"], "data")
    guard let firstSkill = skillsData.first as? [String: Any] else {
      throw ToolError.message("list_skills returned no skills")
    }
    try Check.equal(
      try JSON.string(firstSkill["name"], "name"), "ui-diagnostics", JSON.text(skills))

    let skill = try tool("read_skill", ["name": "ui-diagnostics"])
    let skillData = try JSON.object(
      try JSON.object(skill["structuredContent"], "structuredContent")["data"], "data")
    let guide = try JSON.string(skillData["instructions"], "instructions")

    let prompt = try request("prompts/get", ["name": "ui-diagnostics"])
    let messages = try JSON.array(prompt["messages"], "messages")
    guard let firstMessage = messages.first as? [String: Any] else {
      throw ToolError.message("prompts/get returned no messages")
    }
    let content = try JSON.object(firstMessage["content"], "content")
    let promptText = try JSON.string(content["text"], "text")
    try Check.equal(guide, promptText, "The shared skill and prompt disagree")

    let missing = try tool("query_ui_nodes")
    try Check.equal(try JSON.boolean(missing["isError"], "isError"), true, JSON.text(missing))
    let pieces = try JSON.array(missing["content"], "content")
    guard let firstPiece = pieces.first as? [String: Any] else {
      throw ToolError.message("query_ui_nodes returned no content")
    }
    try Check.contains(
      try JSON.string(firstPiece["text"], "text"), "unavailable", JSON.text(missing))

    let console = try tool("get_console_messages")
    try Check.equal(try JSON.boolean(console["isError"], "isError"), false, JSON.text(console))

    mcp.closeInput()
    guard mcp.wait(timeout: 10) == 0 else {
      throw ToolError.message("The MCP server did not exit cleanly")
    }
  }
}

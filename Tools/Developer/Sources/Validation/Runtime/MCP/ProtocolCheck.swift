internal import Foundation
internal import ToolSupport

/// Port of `scripts/check-diffuse-mcp-protocol.py`: drives the real stdio server
/// with framing, malformed input, negotiation, ping, tools and disconnect
/// cases, with no running editor or model key.
enum MCPProtocolCheck {
  static let usage = """
    cove-dev validate mcp-protocol

    Runs the built DiffuseMCP stdio server against its protocol edge cases.
    Honors DIFFUSE_MCP_EXECUTABLE to select the server executable.
    """

  static func run(_ arguments: [String]) throws {
    if arguments.contains("-h") || arguments.contains("--help") {
      Terminal.info(usage)
      return
    }
    if let unexpected = arguments.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }

    let server = try BuildProducts.mcpServer()
    let input = Data(requests.joined(separator: "\n").appending("\n").utf8)
    var environment = ProcessInfo.processInfo.environment
    environment["DIFFUSE_MCP_PORT"] = "1"
    let outcome = try Subprocess.run(server, environment: environment, input: input, timeout: 10)
    guard outcome.status == 0 else {
      throw ToolError.message(
        outcome.stderrText.isEmpty
          ? "DiffuseMCP exited with status \(outcome.status)"
          : outcome.stderrText)
    }

    let messages = try parse(outcome.stdout)
    guard messages.count == 11 else { throw ToolError.message(JSON.text(messages)) }
    var byID: [Int?: [String: Any]] = [:]
    for message in messages { byID[try identifier(of: message)] = message }

    try Check.equal(try errorCode(byID[nil]), -32700, JSON.text(messages))
    try Check.equal(try errorCode(byID[1]), -32600, JSON.text(messages))
    try Check.equal(try errorCode(byID[8]), -32602, JSON.text(messages))
    try Check.equal(
      try JSON.string(result(byID[2])["protocolVersion"], "protocolVersion"), "2025-03-26",
      JSON.text(messages))
    try Check.require(result(byID[3]).isEmpty, JSON.text(messages))

    let tools = try JSON.objects(result(byID[4])["tools"], "tools")
    let names = Set(tools.compactMap { $0["name"] as? String })
    let core: Set<String> = [
      "write_script", "compile_scripts", "get_runtime_state", "export_project",
      "search_capabilities", "submit_plan", "reload_plugin",
    ]
    try Check.require(core.isSubset(of: names), JSON.text(messages))
    try Check.require(!names.contains("respond"), JSON.text(messages))
    let diagnostics: Set<String> = [
      "get_diagnostics", "query_ui_nodes", "query_ui_recomposition", "query_ui_state",
      "capture_ui_trace", "get_ui_trace", "compare_ui_traces", "list_skills", "read_skill",
    ]
    try Check.require(diagnostics.isSubset(of: names), JSON.text(messages))

    let prompts = try JSON.objects(result(byID[9])["prompts"], "prompts")
    try Check.require(prompts.first?["name"] as? String == "ui-diagnostics", JSON.text(messages))
    let promptMessages = try JSON.objects(result(byID[10])["messages"], "messages")
    let promptText = try JSON.string(
      try JSON.object(promptMessages.first?["content"], "content")["text"], "text")
    try Check.contains(promptText, "query_ui_nodes", JSON.text(messages))

    guard let write = tools.first(where: { $0["name"] as? String == "write_script" }) else {
      throw ToolError.message("DiffuseMCP is missing write_script")
    }
    let schema = try JSON.object(write["inputSchema"], "inputSchema")
    try Check.equal(
      try JSON.boolean(schema["additionalProperties"], "additionalProperties"), false,
      JSON.text(messages))
    try Check.require(
      !(JSON.strings(schema["required"]) ?? []).contains("expected_sha256"), JSON.text(messages))
    // Disconnection must not appear successful.
    try Check.equal(
      try JSON.boolean(result(byID[5])["isError"], "isError"), true, JSON.text(messages))
    try Check.equal(try errorCode(byID[6]), -32601, JSON.text(messages))
    try Check.equal(
      try JSON.string(result(byID[7])["protocolVersion"], "protocolVersion"), "2025-11-25",
      JSON.text(messages))

    Terminal.info(
      "Diffuse MCP protocol passed: framing, malformed input, negotiation, ping, tools and real disconnect errors"
    )
  }

  /// The framed request inventory, matching the Python list token for token.
  private static var requests: [String] {
    [
      JSON.text([
        "jsonrpc": "2.0", "id": 8, "method": "tools/call",
        "params": ["name": "compile_scripts", "arguments": [Any]()],
      ]),
      "",
      "{invalid json",
      JSON.text(["id": 1, "method": "ping"]),
      JSON.text([
        "jsonrpc": "2.0", "id": 2, "method": "initialize",
        "params": ["protocolVersion": "2025-03-26"],
      ]),
      JSON.text(["jsonrpc": "2.0", "method": "notifications/initialized"]),
      JSON.text(["jsonrpc": "2.0", "id": 3, "method": "ping"]),
      JSON.text(["jsonrpc": "2.0", "id": 4, "method": "tools/list"]),
      JSON.text([
        "jsonrpc": "2.0", "id": 5, "method": "tools/call",
        "params": [
          "name": "write_script", "arguments": ["filename": "Game.swift", "source": "source"],
        ],
      ]),
      JSON.text(["jsonrpc": "2.0", "id": 6, "method": "unknown"]),
      JSON.text([
        "jsonrpc": "2.0", "id": 7, "method": "initialize",
        "params": ["protocolVersion": "future-version"],
      ]),
      JSON.text(["jsonrpc": "2.0", "id": 9, "method": "prompts/list"]),
      JSON.text([
        "jsonrpc": "2.0", "id": 10, "method": "prompts/get", "params": ["name": "ui-diagnostics"],
      ]),
    ]
  }

  private static func parse(_ data: Data) throws -> [[String: Any]] {
    var lines = String(decoding: data, as: UTF8.self)
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    if lines.last == "" { lines.removeLast() }
    return try lines.map { try JSON.parseObject(Data($0.utf8)) }
  }

  private static func identifier(of message: [String: Any]) throws -> Int? {
    guard let raw = message["id"] else {
      throw ToolError.message("message without an id: \(JSON.text(message))")
    }
    if raw is NSNull { return nil }
    guard let identifier = raw as? Int else {
      throw ToolError.message("message with a non-integer id: \(JSON.text(message))")
    }
    return identifier
  }

  private static func result(_ message: [String: Any]?) -> [String: Any] {
    (message?["result"] as? [String: Any]) ?? [:]
  }

  private static func errorCode(_ message: [String: Any]?) throws -> Int {
    guard let error = message?["error"] as? [String: Any], let code = JSON.int(error["code"]) else {
      throw ToolError.message(
        "Expected a JSON-RPC error, got \(JSON.text(message ?? [:] as [String: Any]))")
    }
    return code
  }
}

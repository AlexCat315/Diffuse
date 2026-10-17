internal import Foundation
internal import ToolSupport

/// JSON-RPC client for the stdio GuavaMCP server, matching the `MCPClient`
/// the Crystal Rush and editor-loop validations shared. Requests are
/// correlated by id; unrelated messages are dropped, as in the Python.
final class MCPClient {
  private let child: ChildProcess
  private var sequence = 0
  private(set) var transcript: [Any] = []

  init(executable: URL, environment: [String: String]) throws {
    child = try ChildProcess(
      executable, [], environment: environment, stdin: .pipe, stdout: .pipe, stderr: .discard)
  }

  @discardableResult
  func request(_ method: String, _ params: [String: Any]? = nil) throws -> [String: Any] {
    sequence += 1
    let identifier = sequence
    let request: [String: Any] = [
      "jsonrpc": "2.0", "id": identifier, "method": method, "params": params ?? [String: Any](),
    ]
    try child.sendLine(request)
    let deadline = Date().addingTimeInterval(180)
    while Date() < deadline {
      let remaining = min(1, max(0, deadline.timeIntervalSinceNow))
      if let message = try child.readLine(timeout: remaining) {
        guard message["id"] as? Int == identifier else { continue }
        transcript.append(["request": request, "response": message])
        if let error = message["error"] {
          throw ToolError.message(JSON.text(error))
        }
        guard let result = message["result"] as? [String: Any] else {
          throw ToolError.message("\(method) returned no result object: \(JSON.text(message))")
        }
        return result
      }
    }
    throw ToolError.message("Timed out waiting for \(method)")
  }

  @discardableResult
  func tool(_ name: String, _ arguments: [String: Any]? = nil) throws -> [String: Any] {
    let result = try request(
      "tools/call", ["name": name, "arguments": arguments ?? [String: Any]()])
    guard let content = (result["content"] as? [Any])?.first as? [String: Any],
      let text = content["text"] as? String
    else {
      throw ToolError.message("\(name) returned no content: \(JSON.text(result))")
    }
    if JSON.boolean(result["isError"]) == true {
      throw ToolError.message("\(name): \(text)")
    }
    let value = try JSON.parseObject(Data(text.utf8))
    if JSON.boolean(value["ok"]) == false {
      throw ToolError.message("\(name): \(JSON.text(value))")
    }
    return value
  }

  /// Resolves a capability identifier through `search_capabilities`, then
  /// invokes the tool it names.
  func capability(_ identifier: String, _ arguments: [String: Any]) throws -> [String: Any] {
    let search = try tool("search_capabilities", ["query": identifier])
    let capabilities = JSON.objects(search["capabilities"]) ?? []
    guard let item = capabilities.first(where: { $0["id"] as? String == identifier }),
      let toolName = item["tool_name"] as? String
    else {
      throw ToolError.message("Unknown capability \(identifier)")
    }
    return try tool(toolName, arguments)
  }

  /// Submits a scene draft and waits for the headless reviewer to apply it.
  @discardableResult
  func submit(_ draft: [String: Any], _ summary: String) throws -> [String: Any] {
    let before = try JSON.int(tool("get_project_info")["scene_revision"], "scene_revision")
    let result = try tool(
      "submit_plan", ["summary": summary, "draft_ids": [draft["draft_id"] ?? NSNull()]])
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      let info = try tool("get_project_info")
      let pending = JSON.boolean(info["pending_confirmation"]) == true
      let revision = try JSON.int(info["scene_revision"], "scene_revision")
      if !pending, revision > before { return result }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw ToolError.message("Scene preview was not applied by the opt-in headless reviewer")
  }

  func close() {
    child.closeInput()
    if child.wait(timeout: 5) == nil {
      child.terminate()
      _ = child.wait(timeout: 5)
    }
  }
}

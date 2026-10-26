internal import Foundation
internal import ToolSupport

/// Port of `scripts/validate-crystal-rush-mcp.py`: create and validate Crystal
/// Rush through the real Cove MCP stdio server. Source writes, builds, scene
/// drafts, script attachment, save, play inspection and export all use MCP tools.
enum CrystalRush {
  static let usage = """
    cove-dev validate crystal-rush [--project PATH] [--source-file PATH]

      --project      Project directory; defaults to examples/CrystalRush.
      --source-file  Gameplay source to write; defaults to the example's script.
    """

  static func run(_ arguments: [String]) throws {
    var project = Repository.path("examples/CrystalRush")
    var sourceFile: URL?
    var index = 0
    while index < arguments.count {
      let token = arguments[index]
      if token == "-h" || token == "--help" {
        Terminal.info(usage)
        return
      }
      if Flags.matches(token, "--project") {
        project = URL(fileURLWithPath: try Flags.value(token, "--project", arguments, &index))
      } else if Flags.matches(token, "--source-file") {
        sourceFile = URL(
          fileURLWithPath: try Flags.value(token, "--source-file", arguments, &index))
      } else {
        throw ToolError.message("unrecognized arguments: \(token)")
      }
      index += 1
    }
    try validate(
      project: project.resolvingSymlinksInPath().standardizedFileURL, sourceFile: sourceFile)
  }

  private static func validate(project: URL, sourceFile: URL?) throws {
    let root = Repository.root
    let source =
      try sourceFile.map { try Fs.text($0) }
      ?? Fs.text(root.appendingPathComponent("examples/CrystalRush/Scripts/CrystalRush.swift"))
    try Fs.directory(project)
    try prepareScene(project)

    let port = try FreePort.reserve()
    var environment = ProcessInfo.processInfo.environment
    environment["COVE_MCP_PORT"] = String(port)
    let editor = try BuildProducts.executable(package: "Editor", name: "EditorApp")
    let player = try BuildProducts.executable(package: "Editor", name: "CovePlayer")
    let server = try BuildProducts.executable(package: "CoveMcp", name: "CoveMCP")
    environment["COVE_PLAYER_EXECUTABLE"] = player.path

    let log = project.appendingPathComponent("validation/editor.log")
    let logHandle = try openForWriting(log)
    let child = try ChildProcess(
      editor,
      [
        "--mcp-headless", "--project-dir", project.path,
        "--trust-project-scripts", "--approve-scene-edits",
      ],
      environment: environment, stdout: .file(logHandle), stderr: .file(logHandle))
    var client: MCPClient?
    defer {
      if let client {
        try? JSON.write(client.transcript, to: transcriptURL(project), pretty: true)
        client.close()
      }
      child.stop()
    }

    try waitForBridge(child: child, port: port, log: log)
    try EditorBridge.validateConnections(port: port)

    let mcp = try MCPClient(executable: server, environment: environment)
    client = mcp
    let handshake = try mcp.request(
      "initialize",
      [
        "protocolVersion": "2025-11-25", "capabilities": [String: Any](),
        "clientInfo": ["name": "crystal-rush-validation", "version": "1"],
      ])
    Terminal.info(
      "MCP initialized: \(try JSON.string(handshake["protocolVersion"], "protocolVersion"))")

    let tools = try JSON.objects(try mcp.request("tools/list")["tools"], "tools")
    try Check.require(
      tools.contains { $0["name"] as? String == "write_script" }, "CoveMCP is missing write_script"
    )
    let info = try mcp.tool("get_project_info")
    Terminal.info(
      "Project connected; trusted: \(try JSON.boolean(info["script_execution_trusted"], "script_execution_trusted"))"
    )

    var arguments: [String: Any] = ["filename": "CrystalRush.swift", "source": source]
    if BuildProducts.isFile(project.appendingPathComponent("Scripts/CrystalRush.swift")) {
      arguments["expected_sha256"] =
        try mcp.tool("read_script", ["filename": "CrystalRush.swift"])["sha256"] ?? NSNull()
    }
    let written = try mcp.tool("write_script", arguments)
    Terminal.info(
      "Source written through MCP: \(try JSON.string(written["identifier"], "identifier"))")
    let build = try mcp.tool("compile_scripts")
    Terminal.info("Scripts compiled: \(JSON.text(build))")

    var entities = try gameEntities(in: mcp)
    var controller = entities.first { $0["name"] as? String == "Game Controller" }
    if controller == nil {
      let draft = try mcp.capability(
        "scene.spawn_entity", ["label": "Game Controller", "spawn_kind": "empty"])
      try mcp.submit(draft, "Create the Crystal Rush game controller")
      entities = try gameEntities(in: mcp)
      controller = entities.first { $0["name"] as? String == "Game Controller" }
    }
    guard let entity = controller else {
      throw ToolError.message("The Game Controller entity was not created")
    }

    let draft = try mcp.capability(
      "scene.set_script_property",
      [
        "entity_id": entity["id"] ?? NSNull(),
        "script_identifier": written["identifier"] ?? NSNull(),
        "script_property_name": "title",
        "script_property_value": "Crystal Rush",
      ])
    try mcp.submit(draft, "Attach the compiled gameplay with its stable script identifier")
    let saved = try mcp.tool("save_scene")
    Terminal.info("Scene saved: \(try JSON.string(saved["path"], "path"))")

    try mcp.tool("set_playback_state", ["state": "playing"])
    let runtime = try waitForRuntime(mcp, timeout: 5)
    try Check.require(
      try JSON.int(runtime["entity_count"], "entity_count") > 50, JSON.text(runtime))
    try Check.require((JSON.list(runtime["unresolved_bindings"]) ?? []).isEmpty, JSON.text(runtime))
    guard let script = (JSON.objects(runtime["scripts"]) ?? []).first else {
      throw ToolError.message("No gameplay scripts were running: \(JSON.text(runtime))")
    }
    let values = try JSON.object(script["values"], "values")
    try Check.equal(try JSON.string(values["phase"], "phase"), "ready", JSON.text(runtime))
    Terminal.info("Live gameplay state: \(JSON.text(runtime))")

    try mcp.tool("set_playback_state", ["state": "stopped"])
    let exported = try mcp.tool("export_project")
    try Check.require(try JSON.boolean(exported["runnable"], "runnable"), JSON.text(exported))
    let executable = try JSON.string(exported["executable"], "executable")
    Terminal.info("Runnable game: \(executable)")

    var isolated = ProcessInfo.processInfo.environment
    isolated["PATH"] = "/cove-no-toolchain"
    isolated.removeValue(forKey: "COVE_PROJECT_DIR")
    let validation = try Subprocess.run(
      URL(fileURLWithPath: executable),
      arguments: ["--validate-project", "--simulation-frames", "120"],
      environment: isolated, timeout: 30)
    guard validation.status == 0 else { throw ToolError.message(validation.stderrText) }
    Terminal.info(validation.stdoutText)
  }

  private static func prepareScene(_ project: URL) throws {
    let scene = project.appendingPathComponent(".cove/editor-scene-manifest.json")
    try Fs.directory(scene.deletingLastPathComponent())
    guard !BuildProducts.isFile(scene) else { return }
    try Fs.write(
      try JSON.compact(["schemaVersion": 8, "revision": 0, "entityCount": 0, "roots": [Any]()]),
      to: scene)
  }

  private static func waitForBridge(child: ChildProcess, port: UInt16, log: URL) throws {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      if !child.isRunning { throw ToolError.message(try readText(log)) }
      if let probe = try? TCPClient(host: "127.0.0.1", port: port, timeout: 0.2) {
        probe.close()
        return
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw ToolError.message("Headless editor did not bind its loopback bridge")
  }

  private static func waitForRuntime(_ client: MCPClient, timeout: TimeInterval) throws -> [String:
    Any]
  {
    let deadline = Date().addingTimeInterval(timeout)
    var runtime = try client.tool("get_runtime_state")
    while Date() < deadline {
      if !(JSON.list(runtime["scripts"]) ?? []).isEmpty { break }
      Thread.sleep(forTimeInterval: 0.1)
      runtime = try client.tool("get_runtime_state")
    }
    return runtime
  }

  private static func gameEntities(in client: MCPClient) throws -> [[String: Any]] {
    let scene = try JSON.object(
      try client.capability("scene.get_entities", [String: Any]())["scene"], "scene")
    return try JSON.objects(scene["entities"] ?? [Any](), "entities")
  }

  private static func transcriptURL(_ project: URL) -> URL {
    project.appendingPathComponent("validation/mcp-transcript.json")
  }
}

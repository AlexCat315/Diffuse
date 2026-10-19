internal import Foundation
internal import ToolSupport

/// Port of `scripts/validate-editor-native-loop.py`: build a disposable `.app`,
/// launch the real editor on a real window, and drive MCP compilation, reload,
/// playback and export plus the in-process capture and timing helpers.
///
/// The disposable bundle, project, trust decision, logs and transcript stay in
/// a new temporary directory that is kept and printed.
enum EditorNativeLoop {
  static let usage = """
    guava-dev validate editor-loop [--mode both|event-driven|continuous] [--renderer native|metal]
                                   [--configuration debug|release] [--timing-frames N]

      --mode            Which frame loops to run; defaults to both.
      --renderer        Editor renderer to select; defaults to native.
      --configuration   Editor build configuration; defaults to debug.
      --timing-frames   Record presented window timings after 60 warmup frames;
                        requires --mode continuous.
    """

  static func run(_ arguments: [String]) throws {
    #if !canImport(Darwin)
      throw ToolError.message("The native editor TCP bridge currently requires macOS")
    #else
      var mode = "both"
      var renderer = "native"
      var configuration = "debug"
      var timingFrames = 0
      var index = 0
      while index < arguments.count {
        let token = arguments[index]
        if token == "-h" || token == "--help" {
          Terminal.info(usage)
          return
        }
        if Flags.matches(token, "--mode") {
          mode = try Flags.value(token, "--mode", arguments, &index)
        } else if Flags.matches(token, "--renderer") {
          renderer = try Flags.value(token, "--renderer", arguments, &index)
        } else if Flags.matches(token, "--configuration") {
          configuration = try Flags.value(token, "--configuration", arguments, &index)
        } else if Flags.matches(token, "--timing-frames") {
          let raw = try Flags.value(token, "--timing-frames", arguments, &index)
          guard let parsed = Int(raw) else {
            throw ToolError.message("argument --timing-frames: invalid int value: '\(raw)'")
          }
          timingFrames = parsed
        } else {
          throw ToolError.message("unrecognized arguments: \(token)")
        }
        index += 1
      }
      guard ["both", "event-driven", "continuous"].contains(mode) else {
        throw ToolError.message(
          "argument --mode: invalid choice: '\(mode)' (choose from 'both', 'event-driven', 'continuous')"
        )
      }
      guard ["native", "metal"].contains(renderer) else {
        throw ToolError.message(
          "argument --renderer: invalid choice: '\(renderer)' (choose from 'native', 'metal')")
      }
      guard ["debug", "release"].contains(configuration) else {
        throw ToolError.message(
          "argument --configuration: invalid choice: '\(configuration)' (choose from 'debug', 'release')"
        )
      }
      guard timingFrames >= 0, timingFrames == 0 || mode == "continuous" else {
        throw ToolError.message("--timing-frames requires a positive count and --mode continuous")
      }

      let directory = try Temp.directory(prefix: "guava-native-validation-")
      Terminal.info("Validation artifacts: \(directory.path)")
      let modes = [false, true].filter { mode == "both" || (mode == "continuous") == $0 }
      let rendererDirectory = directory.appendingPathComponent(renderer)
      try Fs.directory(rendererDirectory)
      for continuous in modes {
        try validate(
          directory: rendererDirectory.appendingPathComponent(
            continuous ? "continuous" : "event-driven"),
          continuous: continuous, renderer: renderer,
          configuration: configuration, timingFrames: timingFrames)
      }
    #endif
  }

  private static func validate(
    directory: URL, continuous: Bool, renderer: String,
    configuration: String, timingFrames: Int
  ) throws {
    try Fs.directory(directory)
    let editor = try BuildProducts.executable(
      package: "Editor", name: "EditorApp", configuration: configuration)
    let player = try BuildProducts.executable(
      package: "Editor", name: "GuavaPlayer", configuration: configuration)
    let server = try BuildProducts.executable(package: "GuavaMcp", name: "GuavaMCP")
    let root = Repository.root

    let project = directory.appendingPathComponent("Crystal Rush")
    let scripts = project.appendingPathComponent("Scripts")
    let metadata = project.appendingPathComponent(".guava")
    try Fs.directory(scripts)
    try Fs.directory(metadata)
    let resources = root.appendingPathComponent(
      "Editor/Sources/EditorCore/Resources/ProjectTemplates")
    try Fs.copy(
      resources.appendingPathComponent("crystal-rush.swift.txt"),
      to: scripts.appendingPathComponent("CrystalRush.swift"))
    try Fs.copy(
      resources.appendingPathComponent("crystal-rush.scene.json"),
      to: metadata.appendingPathComponent("editor-scene-manifest.json"))
    try Fs.copy(
      resources.appendingPathComponent("crystal-rush.script-assets.json"),
      to: metadata.appendingPathComponent("script-assets.json"))

    let bundleIdentifier = "org.guava.native-validation.\(UUID().uuidString.lowercased())"
    let macOS = try assembleBundle(
      directory: directory, editor: editor, bundleIdentifier: bundleIdentifier)

    let state = directory.appendingPathComponent("editor-state")
    try Fs.directory(state)
    let trust: [String: Any] = [
      "version": 1, "trustedProjectPaths": [project.path, project.standardizedFileURL.path],
    ]
    try Fs.write(
      try JSON.compact(trust), to: state.appendingPathComponent("script-workspace-trust.json"))

    let port = try FreePort.reserve()
    let devtoolsPort = try FreePort.reserve()
    var environment = ProcessInfo.processInfo.environment
    environment["GUAVA_MCP_PORT"] = String(port)
    environment["GUAVA_EDITOR_STATE_DIRECTORY"] = state.path
    environment["GUAVA_PLAYER_EXECUTABLE"] = player.path
    environment["GUAVAUI_FORCE_CONTINUOUS_FRAMES"] = continuous ? "1" : "0"
    environment["GUAVA_DEVTOOLS"] = "1"
    environment["GUAVA_DEVTOOLS_PORT"] = String(devtoolsPort)
    environment["GUAVA_DEVTOOLS_AUTO_LOG_TAP"] = "0"

    let log = directory.appendingPathComponent("editor.log")
    let logHandle = try openForWriting(log)
    let child = try ChildProcess(
      macOS.appendingPathComponent("GuavaNativeValidation"),
      ["--project-dir", project.path, "--renderer", renderer],
      environment: environment, stdout: .file(logHandle), stderr: .file(logHandle))
    var client: MCPClient?
    defer {
      if let client {
        try? JSON.write(
          client.transcript, to: directory.appendingPathComponent("mcp-transcript.json"),
          pretty: true)
        client.close()
      }
      child.stop()
      // Delete only this run's dedicated preferences domain.
      if let defaults = try? Shell.require("defaults") {
        _ = try? Subprocess.run(defaults, arguments: ["delete", bundleIdentifier], timeout: 10)
      }
    }

    try waitForBridge(child: child, port: port, log: log, renderer: renderer)
    let startup = try readText(log)
    try Check.contains(startup, "NativeRenderer ready", tail(startup))
    try CaptureUI.capture(
      endpoint: DevToolsEndpoint.resolve(String(devtoolsPort)), destination: directory.appendingPathComponent("startup-editor.jpg"))
    try EditorBridge.validateConnections(port: port)

    let mcp = try MCPClient(executable: server, environment: environment)
    client = mcp
    try mcp.request(
      "initialize",
      [
        "protocolVersion": "2025-11-25", "capabilities": [String: Any](),
        "clientInfo": ["name": "native-editor-validation", "version": "1"],
      ])
    let info = try mcp.tool("get_project_info")
    let scriptable = try JSON.boolean(info["script_sdk_available"], "script_sdk_available")
    let trusted = try JSON.boolean(info["script_execution_trusted"], "script_execution_trusted")
    try Check.require(scriptable && trusted, JSON.text(info))
    let freshProject =
      try JSON.int(info["entity_count"], "entity_count") == 1
      && JSON.boolean(info["pending_confirmation"]) != true
    try Check.require(freshProject, JSON.text(info))

    try mcp.tool("compile_scripts")
    let source = try mcp.tool("read_script", ["filename": "CrystalRush.swift"])
    let original = try JSON.string(source["source"], "source")
    let changed = replacingFirst(
      original, "\"phase\": phase",
      with: "\"phase\": phase, \"validation_generation\": \"native-loop\"")
    try Check.require(
      changed != original, "The gameplay script did not contain the expected anchor")
    try mcp.tool(
      "write_script",
      [
        "filename": "CrystalRush.swift", "source": changed,
        "expected_sha256": source["sha256"] ?? NSNull(),
      ])
    try mcp.tool("compile_scripts")
    try mcp.tool("save_scene")

    var previousFrame = try frameIndex(mcp)
    try mcp.tool("set_playback_state", ["state": "playing"])
    let runtime = try waitForGame(mcp, previousFrame: previousFrame, expecting: 60)
    let entityCount = try JSON.int(runtime["entity_count"], "entity_count")
    try Check.require(
      entityCount == 60 && (JSON.list(runtime["unresolved_bindings"]) ?? []).isEmpty,
      JSON.text(runtime))
    let values = try JSON.object(runtimeScript(runtime)["values"], "values")
    try Check.equal(try JSON.string(values["phase"], "phase"), "ready", JSON.text(runtime))
    try Check.equal(
      try JSON.string(values["validation_generation"], "validation_generation"), "native-loop",
      JSON.text(runtime))
    try Check.require(renderedGame(runtime, previousFrame), JSON.text(runtime))

    if timingFrames > 0 {
      try RecordTimings.record(
        endpoint: DevToolsEndpoint.resolve(String(devtoolsPort)), destination: directory.appendingPathComponent("playing-timings.json"),
        frames: timingFrames, warmup: 60)
    }
    try mcp.tool("set_playback_state", ["state": "paused"])
    try Check.equal(
      try JSON.string(try mcp.tool("get_project_info")["playback_state"], "playback_state"),
      "paused", "Paused playback state")
    try CaptureUI.capture(
      endpoint: DevToolsEndpoint.resolve(String(devtoolsPort)), destination: directory.appendingPathComponent("paused-editor.jpg"))
    if timingFrames > 0 {
      try RecordTimings.record(
        endpoint: DevToolsEndpoint.resolve(String(devtoolsPort)), destination: directory.appendingPathComponent("paused-timings.json"),
        frames: timingFrames, warmup: 60)
    }
    try mcp.tool("set_playback_state", ["state": "stopped"])
    try Check.equal(
      try JSON.int(try mcp.tool("get_project_info")["entity_count"], "entity_count"), 1,
      "Stopped playback state")

    previousFrame = try frameIndex(mcp)
    try mcp.tool("set_playback_state", ["state": "playing"])
    let restarted = try waitForGame(mcp, previousFrame: previousFrame, expecting: 60)
    try Check.equal(
      try JSON.int(restarted["entity_count"], "entity_count"), 60, JSON.text(restarted))
    try Check.require(renderedGame(restarted, previousFrame), JSON.text(restarted))
    let restartedValues = try JSON.object(runtimeScript(restarted)["values"], "values")
    try Check.equal(
      try JSON.string(restartedValues["phase"], "phase"), "ready", JSON.text(restarted))
    try mcp.tool("set_playback_state", ["state": "stopped"])

    try exportAndValidate(mcp)

    let applicationLog = try readText(log)
    for failure in [
      "native scene render failed:", "[EngineHost] NativeRHI renderer initialization failed:",
      "render failed:",
    ] {
      try Check.require(!applicationLog.contains(failure), tail(applicationLog))
    }
    Terminal.info(
      "\(continuous ? "Continuous" : "Event-driven") \(renderer) loop passed: compile, reload, Play/Pause/Stop, export"
    )
  }

  /// Builds the disposable `.app` bundle that mirrors the developer SDK layout
  /// the editor already discovers.
  private static func assembleBundle(directory: URL, editor: URL, bundleIdentifier: String) throws
    -> URL
  {
    let bundle = directory.appendingPathComponent("GuavaNativeValidation.app")
    let macOS = bundle.appendingPathComponent("Contents/MacOS")
    try Fs.directory(macOS)
    try Fs.copy(editor, to: macOS.appendingPathComponent("GuavaNativeValidation"))
    let plist: [String: Any] = [
      "CFBundleExecutable": "GuavaNativeValidation",
      "CFBundleName": "GuavaNativeValidation",
      "CFBundleIdentifier": bundleIdentifier,
      "CFBundlePackageType": "APPL",
      "CFBundleVersion": "1",
      "NSHighResolutionCapable": true,
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try Fs.write(data, to: bundle.appendingPathComponent("Contents/Info.plist"))

    let bundledResources = bundle.appendingPathComponent("Contents/Resources")
    try Fs.directory(bundledResources)
    let products = editor.deletingLastPathComponent()
    for resource in Glob.paths(in: products, matching: "*.bundle") {
      try? FileManager.default.createSymbolicLink(
        at: bundledResources.appendingPathComponent(resource.lastPathComponent),
        withDestinationURL: resource)
    }
    let modules = products.appendingPathComponent("Modules")
    let moduleRoot = FileManager.default.fileExists(atPath: modules.path) ? modules : products
    try? FileManager.default.createSymbolicLink(
      at: macOS.appendingPathComponent("Modules"), withDestinationURL: moduleRoot)

    let maps = products.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Intermediates.noindex/GeneratedModuleMaps")
    let moduleMaps =
      Glob.paths(in: maps, matching: "C*.modulemap")
      + Glob.paths(in: products, matching: "C*.build/module.modulemap")
    for moduleMap in moduleMaps {
      let name =
        moduleMap.lastPathComponent == "module.modulemap"
        ? moduleMap.deletingLastPathComponent().lastPathComponent + ".modulemap"
        : moduleMap.lastPathComponent
      try? FileManager.default.createSymbolicLink(
        at: macOS.appendingPathComponent(name), withDestinationURL: moduleMap)
    }
    return macOS
  }

  private static func waitForBridge(child: ChildProcess, port: UInt16, log: URL, renderer: String)
    throws
  {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
      if !child.isRunning { throw ToolError.message(tail(try readText(log))) }
      if let probe = try? TCPClient(host: "127.0.0.1", port: port, timeout: 0.2) {
        probe.close()
        // Bridge startup can precede scene renderer initialization.
        if try readText(log).contains("NativeRenderer ready") { return }
      }
      Thread.sleep(forTimeInterval: 0.1)
    }
    throw ToolError.message(
      "The editor did not start its bridge and \(renderer) renderer: \(tail(try readText(log)))")
  }

  private static func waitForGame(
    _ client: MCPClient, previousFrame: Int, expecting entityCount: Int
  ) throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(10)
    var runtime = try client.tool("get_runtime_state")
    while Date() < deadline {
      if JSON.int(runtime["entity_count"]) == entityCount,
        !(JSON.list(runtime["scripts"]) ?? []).isEmpty,
        renderedGame(runtime, previousFrame)
      {
        break
      }
      Thread.sleep(forTimeInterval: 0.1)
      runtime = try client.tool("get_runtime_state")
    }
    return runtime
  }

  private static func runtimeScript(_ runtime: [String: Any]) throws -> [String: Any] {
    guard let script = (JSON.objects(runtime["scripts"]) ?? []).first else {
      throw ToolError.message("No gameplay scripts were running: \(JSON.text(runtime))")
    }
    return script
  }

  private static func renderedGame(_ runtime: [String: Any], _ previousFrame: Int) -> Bool {
    guard let render = runtime["render"] as? [String: Any] else { return false }
    return JSON.boolean(render["viewport_valid"]) == true
      && (JSON.int(render["frame_index"]) ?? 0) > previousFrame
      && (JSON.int(render["visible_mesh_instances"]) ?? 0) > 0
      && (JSON.int(render["draw_call_count"]) ?? 0) > 0
  }

  private static func frameIndex(_ client: MCPClient) throws -> Int {
    let runtime = try client.tool("get_runtime_state")
    let render = try JSON.object(runtime["render"], "render")
    return try JSON.int(render["frame_index"], "frame_index")
  }

  /// `str.replace(old, new, 1)` — only the first occurrence changes.
  private static func replacingFirst(_ text: String, _ target: String, with replacement: String)
    -> String
  {
    guard let range = text.range(of: target) else { return text }
    return text.replacingCharacters(in: range, with: replacement)
  }

  /// Exports and then runs the exported player with no toolchain available.
  private static func exportAndValidate(_ client: MCPClient) throws {
    let exported = try client.tool("export_project")
    try Check.require(try JSON.boolean(exported["runnable"], "runnable"), JSON.text(exported))
    let executable = try JSON.string(exported["executable"], "executable")
    var isolated = ProcessInfo.processInfo.environment
    isolated["PATH"] = "/guava-no-toolchain"
    isolated.removeValue(forKey: "GUAVA_PROJECT_DIR")
    let validation = try Subprocess.run(
      URL(fileURLWithPath: executable),
      arguments: ["--validate-project", "--simulation-frames", "120"],
      environment: isolated, timeout: 30)
    guard validation.status == 0 else { throw ToolError.message(validation.stderrText) }
    Terminal.info(validation.stdoutText)
  }
}

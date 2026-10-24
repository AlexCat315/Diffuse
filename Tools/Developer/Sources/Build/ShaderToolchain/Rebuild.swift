internal import Foundation
internal import ToolSupport

/// Rebuilds the bundled NativeRHI renderer artifacts with the pinned offline
/// Slang compiler. Faithful port of `scripts/compile-native-renderer-shaders.py`.
enum RebuildCommand {
  enum System { case render, ui }

  struct Program {
    let system: System
    let directory: URL
    let name: String
    let source: String
    let stages: [(stage: String, entry: String)]
  }

  struct Destination {
    let staged: URL
    let destination: URL
  }

  static let definitions = [
    ArgumentDefinition(name: "--slangc", arity: 1),
    ArgumentDefinition(
      name: "--targets", arity: -1, choices: ["metal", "spirv", "spirv-mobile", "dxil"]),
    ArgumentDefinition(name: "--check", arity: 0),
    ArgumentDefinition(name: "--ui-only", arity: 0),
  ]

  static let particleKernels: [(String, String)] = [
    ("particle_simulate", "particleSimulate"),
    ("particle_spawn_append", "particleSpawn"),
    ("particle_state_clear", "particleClear"),
    ("particle_state_compact", "particleCompact"),
    ("particle_metadata_reset", "particleMetadataReset"),
    ("particle_state_finalize", "particleFinalize"),
    ("particle_sort_prepare", "particleSortPrepare"),
    ("particle_sort_bitonic", "particleSortBitonic"),
    ("particle_sim_to_instance", "particleSimToInstance"),
  ]

  static let fixedShaders: [(String, String, [(String, String)])] = [
    ("editor_grid", "editor_grid.slang", [("vertex", "gridVertex"), ("fragment", "gridFragment")]),
    ("opaque_mesh", "opaque_mesh.slang", [("vertex", "meshVertex"), ("fragment", "meshFragment")]),
    (
      "shadow_mesh", "shadow_mesh.slang",
      [("vertex", "meshVertex"), ("fragment", "shadowFragment")]
    ),
    ("skybox", "skybox.slang", [("vertex", "skyVertex"), ("fragment", "skyFragment")]),
    ("tonemap", "tonemap.slang", [("vertex", "toneVertex"), ("fragment", "toneFragment")]),
    ("opaque_depth", "opaque_mesh.slang", [("fragment", "depthFragment")]),
    (
      "stylized_character", "stylized_character.slang",
      [("vertex", "meshVertex"), ("fragment", "stylizedFragment")]
    ),
    ("outline", "outline.slang", [("vertex", "outlineVertex"), ("fragment", "outlineFragment")]),
    (
      "particles", "particles.slang",
      [("vertex", "particleVertex"), ("fragment", "particleFragment")]
    ),
    ("particle_cull_compact", "particle_cull_compact.slang", [("compute", "particleCull")]),
  ]

  static let postShaders = ["ssao", "ssr", "taa", "bloom", "fxaa", "ink_paper_post"]

  static func run(_ arguments: [String]) throws {
    let parsed = try ArgumentParser.parse(arguments, definitions: definitions, positionalCount: 0)
    var compiler = parsed.value("--slangc") ?? ProcessInfo.processInfo.environment["SLANGC"]
    if compiler == nil || compiler!.isEmpty {
      let bundled = Repository.path("Engine/vendor/slang/bin/slangc")
      if FileManager.default.fileExists(atPath: bundled.path) {
        compiler = bundled.path
      } else {
        throw ToolError.message("Supply --slangc or SLANGC (Slang \(slangVersion))")
      }
    }
    guard let compiler else {
      throw ToolError.message("Supply --slangc or SLANGC (Slang \(slangVersion))")
    }
    let targets = parsed.list("--targets") ?? ["metal", "spirv"]
    let check = parsed.isPresent("--check")
    let uiOnly = parsed.isPresent("--ui-only")
    let programs = buildPrograms(uiOnly: uiOnly)
    let specialized = Set(particleKernels.map { $0.0 })
      .subtracting(["particle_metadata_reset", "particle_state_finalize"])
    let particleNames = Set(particleKernels.map { $0.0 })

    let staging = try makeTemporaryDirectory(prefix: "guava-native-shaders-")
    defer { try? FileManager.default.removeItem(at: staging) }
    var destinations: [Destination] = []
    for target in targets {
      let compilerTarget = target == "spirv-mobile" ? "spirv" : target
      let fixedWorkgroups = target == "dxil" || target == "spirv-mobile"
      for program in programs {
        if target == "spirv-mobile" && program.system == .ui { continue }
        for stage in program.stages {
          let destination = program.directory.appendingPathComponent(
            "Native/\(target)/\(program.name).\(stage.stage).json")
          let output = staging.appendingPathComponent(Fs.relative(destination, to: Repository.root))
          destinations.append(Destination(staged: output, destination: destination))
          let variable = specialized.contains(program.name)
          var defines: [(String, String)]?
          if fixedWorkgroups && particleNames.contains(program.name) {
            defines = [("PARTICLE_WORKGROUP_SIZE", "64")]
          }
          if program.name == "ui" {
            defines = [("UI_VERTEX_SHADER", stage.stage == "vertex" ? "1" : "0")]
          }
          if program.name == "ui_backdrop" {
            defines = [("BACKDROP_VERTEX_SHADER", stage.stage == "vertex" ? "1" : "0")]
          }
          let profile =
            (target == "spirv-mobile" || program.name == "ui" || program.name == "ui_backdrop")
            ? "spirv_1_3" : "spirv_1_5"
          let artifact = try compileShader(
            CompileRequest(
              source: program.directory.appendingPathComponent("Slang/\(program.source)"),
              entry: stage.entry, stage: stage.stage, target: compilerTarget, output: output,
              compiler: compiler,
              threadgroupSize: variable ? [64, 1, 1] : nil,
              lineDirectives: false,
              threadgroupConstants: variable && !fixedWorkgroups ? [0, nil, nil] : nil,
              defines: defines, spirvProfile: profile))
          Terminal.info(Fs.relative(destination, to: Repository.root))
          if variable && fixedWorkgroups {
            try writeWorkgroupFamily(
              program: program, stage: stage, target: target,
              compiler: compiler, artifact: artifact,
              output: output, destination: destination, destinations: &destinations)
          }
        }
      }
    }
    try finish(destinations: destinations, check: check)
  }

  private static func buildPrograms(uiOnly: Bool) -> [Program] {
    let renderShaders = Repository.path("Engine/Sources/RenderBackend/Resources/Shaders")
    let sdkRoot = ProcessInfo.processInfo.environment["GUAVA_SDK_ROOT"]
      .map { URL(fileURLWithPath: $0) } ?? Repository.path("GuavaUI")
    let uiShaders = sdkRoot.appendingPathComponent("Sources/GuavaUIRuntime/Resources/Shaders")
    var programs: [(String, String, [(String, String)])] = []
    if !uiOnly {
      programs = fixedShaders
      programs += postShaders.map {
        ($0, "\($0).slang", [("vertex", "postVertex"), ("fragment", "postFragment")])
      }
      programs += particleKernels.map { ($0.0, "\($0.0).slang", [("compute", $0.1)]) }
    }
    programs.append(("ui", "ui.slang", [("vertex", "uiVertex"), ("fragment", "uiFragment")]))
    programs.append(
      (
        "ui_backdrop", "ui_backdrop.slang",
        [("vertex", "backdropVertex"), ("fragment", "backdropFragment")]
      ))
    return programs.map { name, source, stages in
      let system: System = (name == "ui" || name == "ui_backdrop") ? .ui : .render
      return Program(
        system: system,
        directory: system == .ui ? uiShaders : renderShaders,
        name: name, source: source,
        stages: stages.map { (stage: $0.0, entry: $0.1) })
    }
  }

  /// DXIL and mobile SPIR-V use fixed workgroups: keep one reflected interface
  /// and a complete 1...256 code family without 256 duplicate layouts.
  private static func writeWorkgroupFamily(
    program: Program, stage: (stage: String, entry: String), target: String,
    compiler: String, artifact: JSONValue, output: URL,
    destination: URL, destinations: inout [Destination]
  ) throws {
    var codes: [(String, JSONValue)] = [("64", artifact["code"] ?? .null)]
    let variantDirectory = try makeTemporaryDirectory(prefix: "guava-dxil-workgroups-")
    defer { try? FileManager.default.removeItem(at: variantDirectory) }
    for size in 1...256 where size != 64 {
      let variant = try compileShader(
        CompileRequest(
          source: program.directory.appendingPathComponent("Slang/\(program.source)"),
          entry: stage.entry, stage: stage.stage,
          target: target == "spirv-mobile" ? "spirv" : target,
          output: variantDirectory.appendingPathComponent("shader.json"),
          compiler: compiler, threadgroupSize: nil, lineDirectives: false,
          threadgroupConstants: nil,
          defines: [("PARTICLE_WORKGROUP_SIZE", String(size))],
          spirvProfile: target == "spirv-mobile" ? "spirv_1_3" : "spirv_1_5"))
      let interface = (variant["interface"] ?? .object([]))
        .setting("threadgroupSize", to: artifact["interface"]?["threadgroupSize"] ?? .null)
      if interface != (artifact["interface"] ?? .null) {
        throw ToolError.message("\(target) workgroup variant changes reflected ABI")
      }
      codes.append((String(size), variant["code"] ?? .null))
    }
    let familyName = "\(program.name).compute.workgroups.json"
    let family = output.deletingLastPathComponent().appendingPathComponent(familyName)
    destinations.append(
      Destination(
        staged: family,
        destination: destination.deletingLastPathComponent().appendingPathComponent(familyName)))
    let document = JSONValue.object([("base", artifact), ("variants", .object(codes))])
    try Fs.write(document.prettyPrinted() + "\n", to: family)
  }

  private static func finish(destinations: [Destination], check: Bool) throws {
    var pairs: [(staged: URL, destination: URL)] = []
    for item in destinations {
      let stagedReflection = reflectionURL(for: item.staged)
      if FileManager.default.fileExists(atPath: stagedReflection.path) {
        pairs.append((stagedReflection, reflectionURL(for: item.destination)))
      }
      pairs.append((item.staged, item.destination))
    }
    if check {
      var stale: [String] = []
      for pair in pairs {
        guard FileManager.default.fileExists(atPath: pair.destination.path) else {
          stale.append(Fs.relative(pair.destination, to: Repository.root))
          continue
        }
        if try JSONParser.parse(Fs.text(pair.staged)) != JSONParser.parse(Fs.text(pair.destination))
        {
          stale.append(Fs.relative(pair.destination, to: Repository.root))
        }
      }
      if !stale.isEmpty {
        throw ToolError.message("Stale native shader artifacts:\n" + stale.joined(separator: "\n"))
      }
      Terminal.info("Verified \(destinations.count) bundled shader artifacts")
    } else {
      for pair in pairs {
        try Fs.directory(pair.destination.deletingLastPathComponent())
        let pending = pair.destination.deletingLastPathComponent()
          .appendingPathComponent(".guava-shader-\(UUID().uuidString).tmp")
        defer { try? Fs.remove(pending) }
        try Fs.write(try Fs.read(pair.staged), to: pending)
        try Fs.replace(pending, at: pair.destination)
      }
    }
  }
}

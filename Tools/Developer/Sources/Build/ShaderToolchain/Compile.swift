internal import Foundation
internal import ToolSupport

struct CompileRequest {
  var source: URL
  var entry: String
  var stage: String
  var target: String
  var output: URL
  var compiler: String
  var threadgroupSize: [Int]?
  var lineDirectives: Bool = true
  var threadgroupConstants: [Int?]?
  var defines: [(String, String)]?
  var spirvProfile: String = "spirv_1_5"
  var dxcPath: String? = nil
}

private let specializationTypes = ["uint32", "int32", "float32", "bool"]

/// Compiles one entry point offline into NativeRHI's compiler-independent
/// artifact. Faithful port of `scripts/compile-rhi-shader.py`.
@discardableResult
func compileShader(_ request: CompileRequest) throws -> JSONValue {
  let version = try runTool([request.compiler, "-version"])
  guard version == slangVersion else {
    throw ToolError.message("Expected Slang \(slangVersion), got '\(version)'")
  }
  let source = request.source.resolvingSymlinksInPath().path
  let temp = try makeTemporaryDirectory(prefix: "cove-rhi-shader-")
  defer { try? FileManager.default.removeItem(at: temp) }

  let codeName: String
  switch request.target {
  case "metal": codeName = "shader.metal"
  case "spirv": codeName = "shader.spv"
  case "dxil": codeName = "shader.dxil"
  default: throw ToolError.message("Unsupported target '\(request.target)'")
  }
  let code = temp.appendingPathComponent(codeName)
  let reflectionFile = temp.appendingPathComponent("reflection.json")

  var arguments = [
    request.compiler, source, "-entry", request.entry, "-stage", request.stage,
    "-target", request.target, "-o", code.path, "-reflection-json", reflectionFile.path,
  ]
  if request.target == "spirv" {
    arguments += ["-fvk-use-entrypoint-name", "-profile", request.spirvProfile]
  }
  if request.target == "dxil" { arguments += ["-profile", "sm_6_6"] }
  if request.target == "dxil",let path = request.dxcPath { arguments += ["-dxc-path",path] }
  if !request.lineDirectives { arguments += ["-line-directive-mode", "none"] }
  for (name, value) in request.defines ?? [] { arguments.append("-D\(name)=\(value)") }
  try runTool(arguments)

  let reflection = try JSONParser.parse(Fs.text(reflectionFile))
  var logicalReflection = reflection
  if request.target != "spirv" {
    let logicalFile = temp.appendingPathComponent("logical.json")
    var logicalArguments = [
      request.compiler, source, "-entry", request.entry, "-stage", request.stage,
      "-target", "spirv", "-o", temp.appendingPathComponent("logical.spv").path,
      "-reflection-json", logicalFile.path, "-fvk-use-entrypoint-name",
    ]
    for (name, value) in request.defines ?? [] { logicalArguments.append("-D\(name)=\(value)") }
    try runTool(logicalArguments)
    logicalReflection = try JSONParser.parse(Fs.text(logicalFile))
  }

  var constants = try Reflection.constants(logicalReflection, stage: request.stage)
  for index in constants.indices {
    let name = constants[index]["name"]?.stringValue ?? ""
    guard
      let parameter = (reflection["parameters"]?.arrayValues ?? []).first(where: {
        $0["name"]?.stringValue == name
      })
    else {
      throw ToolError.message("Reflection is missing push constant '\(name)'")
    }
    if request.target != "spirv" {
      let slot = Reflection.targetBinding(parameter, target: request.target)["index"] ?? .null
      constants[index] = constants[index].setting("slot", to: slot)
    }
  }

  guard
    let entryReflection = (reflection["entryPoints"]?.arrayValues ?? []).first(where: {
      $0["name"]?.stringValue == request.entry
    })
  else {
    throw ToolError.message("Reflection is missing entry point '\(request.entry)'")
  }
  var dimensions = entryReflection["threadGroupSize"]?.arrayValues?.compactMap { $0.intValue }
  if request.stage == "mesh" || request.stage == "task", dimensions == nil,
    request.threadgroupSize == nil
  {
    throw ToolError.message(
      "Slang JSON does not expose mesh/task local size; supply --threadgroup-size X Y Z matching numthreads"
    )
  }

  var specializations: [JSONValue] = []
  for parameter in reflection["parameters"]?.arrayValues ?? [] {
    let binding = Reflection.targetBinding(parameter, target: request.target)
    guard binding["kind"]?.stringValue == "specializationConstant" else { continue }
    guard let scalar = parameter["type"]?["scalarType"]?.stringValue,
      specializationTypes.contains(scalar)
    else {
      throw ToolError.message("Only 32-bit scalar specialization constants are supported")
    }
    specializations.append(
      .object([
        ("id", binding["index"] ?? .null),
        ("name", parameter["name"] ?? .null),
        ("type", .string(scalar)),
      ]))
  }

  let groupValues: [Int?] = request.threadgroupConstants ?? [nil, nil, nil]
  func groupID(_ index: Int) -> Int? { index < groupValues.count ? groupValues[index] : nil }
  if let provided = request.threadgroupConstants {
    guard provided.count == 3, let dims = dimensions else {
      throw ToolError.message(
        "Workgroup constant IDs must correspond to specialized local dimensions")
    }
    for (index, value) in provided.enumerated()
    where value != nil && index < dims.count && dims[index] != 0 {
      throw ToolError.message(
        "Workgroup constant IDs must correspond to specialized local dimensions")
    }
  }

  if let dims = dimensions, dims.contains(0) {
    guard let size = request.threadgroupSize else {
      throw ToolError.message("Specialized local size needs an explicit default size")
    }
    for (index, declared) in dims.enumerated() where index < 3 {
      if declared == 0 {
        let group = groupID(index)
        let supported = specializations.contains { item in
          guard let id = item["id"]?.intValue, let group else { return false }
          let type = item["type"]?.stringValue ?? ""
          return id == group && (type == "uint32" || type == "int32")
        }
        if !supported {
          throw ToolError.message(
            "Specialized local dimension needs a reflected integer constant ID")
        }
      } else if index < size.count, declared != size[index] {
        throw ToolError.message("Explicit local size disagrees with compiler reflection")
      }
    }
    dimensions = size
  } else if let dims = dimensions, let size = request.threadgroupSize, dims != size {
    throw ToolError.message("Explicit local size disagrees with compiler reflection")
  }

  var resolved: [Int]
  if let dims = dimensions, !dims.isEmpty {
    resolved = dims
  } else if let size = request.threadgroupSize, !size.isEmpty {
    resolved = size
  } else {
    resolved = [1, 1, 1]
  }
  guard resolved.count == 3, resolved.allSatisfy({ $0 > 0 }) else {
    throw ToolError.message("Invalid reflected workgroup size")
  }

  let formatName: String
  switch request.target {
  case "metal": formatName = "mslSource"
  case "spirv": formatName = "spirv"
  default: formatName = "dxil"
  }
  let pushConstants = constants.map { $0.removingMember("name") }
  let artifact: JSONValue = .object([
    ("stage", .string(request.stage)),
    ("format", .string(formatName)),
    ("entryPoint", .string(request.entry)),
    ("code", .string(try Fs.read(code).base64EncodedString())),
    (
      "interface",
      .object([
        (
          "threadgroupSize",
          .object([("x", .int(resolved[0])), ("y", .int(resolved[1])), ("z", .int(resolved[2]))])
        ),
        (
          "bindings",
          .array(try Reflection.bindings(reflection, target: request.target, constants: constants))
        ),
        ("specializationConstants", .array(specializations)),
        (
          "threadgroupSpecialization",
          .object([
            ("x", .optionalInt(groupID(0))), ("y", .optionalInt(groupID(1))),
            ("z", .optionalInt(groupID(2))),
          ])
        ),
        ("pushConstants", .array(pushConstants)),
      ])
    ),
    ("compiler", .string("Slang \(version)")),
  ])
  try publish(artifact: artifact, reflection: reflection, request: request)
  return artifact
}

/// Stages both outputs under the artifact's parent, then replaces the
/// reflection and finally the artifact so the artifact is the commit point.
private func publish(artifact: JSONValue, reflection: JSONValue, request: CompileRequest) throws {
  let artifactJSON = artifact.prettyPrinted() + "\n"
  let reflectionJSON = reflection.prettyPrinted() + "\n"
  let parent = request.output.deletingLastPathComponent()
  try Fs.directory(parent)
  let staging = try makeTemporaryDirectory(prefix: ".rhi-publish-", in: parent)
  defer { try? FileManager.default.removeItem(at: staging) }
  try Fs.write(artifactJSON, to: staging.appendingPathComponent("artifact.json"))
  try Fs.write(reflectionJSON, to: staging.appendingPathComponent("reflection.json"))
  try Fs.replace(
    staging.appendingPathComponent("reflection.json"), at: reflectionURL(for: request.output))
  try Fs.replace(staging.appendingPathComponent("artifact.json"), at: request.output)
}

enum CompileCommand {
  static let definitions = [
    ArgumentDefinition(name: "--entry", arity: 1, required: true),
    ArgumentDefinition(
      name: "--stage", arity: 1, required: true,
      choices: ["vertex", "fragment", "compute", "task", "mesh"]),
    ArgumentDefinition(
      name: "--target", arity: 1, required: true, choices: ["metal", "spirv", "dxil"]),
    ArgumentDefinition(name: "--output", arity: 1, required: true),
    ArgumentDefinition(name: "--threadgroup-size", arity: 3),
    ArgumentDefinition(name: "--threadgroup-constants", arity: 3),
    ArgumentDefinition(
      name: "--spirv-profile", arity: 1, choices: ["spirv_1_3", "spirv_1_5", "spirv_1_6"]),
    ArgumentDefinition(name: "--no-line-directives", arity: 0),
    ArgumentDefinition(name: "--slangc", arity: 1),
    ArgumentDefinition(name: "--dxc-path", arity: 1),
  ]

  static func run(_ arguments: [String]) throws {
    let parsed = try ArgumentParser.parse(arguments, definitions: definitions, positionalCount: 1)
    guard let compiler = parsed.value("--slangc") ?? ProcessInfo.processInfo.environment["SLANGC"],
      !compiler.isEmpty
    else {
      throw ToolError.message("Supply --slangc or SLANGC (Slang \(slangVersion))")
    }
    let threadgroupSize = try parsed.list("--threadgroup-size").map {
      try parseIntegers($0, name: "--threadgroup-size")
    }
    let threadgroupConstants = try parsed.list("--threadgroup-constants").map {
      try parseIntegers($0, name: "--threadgroup-constants").map { $0 < 0 ? nil : $0 }
    }
    let request = CompileRequest(
      source: URL(fileURLWithPath: parsed.positionals[0]),
      entry: parsed.value("--entry") ?? "",
      stage: parsed.value("--stage") ?? "",
      target: parsed.value("--target") ?? "",
      output: URL(fileURLWithPath: parsed.value("--output") ?? ""),
      compiler: compiler,
      threadgroupSize: threadgroupSize,
      lineDirectives: !parsed.isPresent("--no-line-directives"),
      threadgroupConstants: threadgroupConstants,
      defines: nil,
      spirvProfile: parsed.value("--spirv-profile") ?? "spirv_1_5",dxcPath: parsed.value("--dxc-path"))
    do {
      _ = try compileShader(request)
    } catch {
      throw ToolError.message("Shader compilation failed: \(error)")
    }
    Terminal.info(parsed.value("--output") ?? "")
  }
}

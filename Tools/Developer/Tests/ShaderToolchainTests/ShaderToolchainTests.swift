import Foundation
import XCTest

@testable import ShaderToolchain

/// Locates the checkout from this source file so fixtures and bundled artifacts
/// resolve without relying on the test runner's working directory.
enum Fixtures {
  static let root: URL = {
    var url = URL(fileURLWithPath: #filePath)
    while url.path != "/" {
      if FileManager.default.fileExists(
        atPath: url.appendingPathComponent("Tools/Developer/Package.swift").path)
      {
        return url
      }
      url.deleteLastPathComponent()
    }
    fatalError("Could not locate repository root")
  }()

  static func path(_ relative: String) -> URL { root.appendingPathComponent(relative) }
}

func makeTestDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(
    "guava-rhi-test-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

func requireSlangc() throws -> String {
  guard let slangc = ProcessInfo.processInfo.environment["SLANGC"], !slangc.isEmpty else {
    throw XCTSkip("Set SLANGC to Slang 2026.19")
  }
  return slangc
}

func spvWords(_ code: String) throws -> [UInt32] {
  let data = try XCTUnwrap(Data(base64Encoded: code))
  return data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
}

final class ReflectionContractTests: XCTestCase {
  func testSpecializationConstantsDoNotOverlapBufferBindings() throws {
    let reflection: JSONValue = .object([
      (
        "parameters",
        .array([
          .object([
            ("name", .string("size")),
            (
              "binding", .object([("kind", .string("specializationConstant")), ("index", .int(0))])
            ),
            ("type", .object([("kind", .string("scalar")), ("scalarType", .string("uint32"))])),
          ]),
          .object([
            ("name", .string("uniforms")),
            ("binding", .object([("index", .int(0))])),
            ("type", .object([("kind", .string("constantBuffer"))])),
          ]),
        ])
      )
    ])
    let names = try Reflection.bindings(reflection).compactMap { $0["name"]?.stringValue }
    XCTAssertEqual(names, ["uniforms"])
  }

  func testOverlappingTargetNamespacesRequireExplicitRemapping() {
    let reflection: JSONValue = .object([
      (
        "parameters",
        .array([
          .object([
            ("name", .string("constants")),
            ("binding", .object([("index", .int(0))])),
            ("type", .object([("kind", .string("constantBuffer"))])),
          ]),
          .object([
            ("name", .string("image")),
            ("binding", .object([("index", .int(0))])),
            (
              "type", .object([("kind", .string("resource")), ("baseShape", .string("texture2D"))])
            ),
          ]),
        ])
      )
    ])
    XCTAssertThrowsError(try Reflection.bindings(reflection)) { error in
      XCTAssertTrue(String(describing: error).contains("overlap"), "unexpected error: \(error)")
    }
  }

  func testBindingArraysAreRejectedInsteadOfFlattened() {
    let reflection: JSONValue = .object([
      (
        "parameters",
        .array([
          .object([
            ("name", .string("images")),
            ("binding", .object([("index", .int(0))])),
            ("type", .object([("kind", .string("array"))])),
          ])
        ])
      )
    ])
    XCTAssertThrowsError(try Reflection.bindings(reflection)) { error in
      XCTAssertTrue(String(describing: error).contains("Unsupported"), "unexpected error: \(error)")
    }
  }
}

final class CompilationContractTests: XCTestCase {
  func testVulkan11ProfileEmitsFixedLocalSizeWithoutMaintenance4() throws {
    let slangc = try requireSlangc()
    let directory = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let artifact = try compileShader(
      CompileRequest(
        source: Fixtures.path("GuavaUI/Runtime/Tests/NativeRHITests/Fixtures/compute.slang"),
        entry: "computeMain", stage: "compute", target: "spirv",
        output: directory.appendingPathComponent("compute.json"),
        compiler: slangc, threadgroupSize: nil, lineDirectives: true,
        threadgroupConstants: nil, defines: nil, spirvProfile: "spirv_1_3"))
    let words = try spvWords(try XCTUnwrap(artifact["code"]?.stringValue))
    XCTAssertEqual(words[1], 0x0001_0300)
    var modes: [(UInt32, UInt32)] = []
    var cursor = 5
    while cursor < words.count {
      let count = UInt32(words[cursor] >> 16)
      let opcode = UInt32(words[cursor] & 0xffff)
      XCTAssertGreaterThan(count, 0)
      if count == 0 { break }
      if opcode == 16 || opcode == 331, cursor + 2 < words.count {
        modes.append((opcode, words[cursor + 2]))
      }
      cursor += Int(count)
    }
    XCTAssertTrue(modes.contains { $0 == (16, 17) })  // OpExecutionMode LocalSize
    XCTAssertFalse(modes.contains { $0 == (331, 38) })  // LocalSizeId requires maintenance4
  }

  func testUIConstantsAreVertexOnlyAndImageBindingsAreStatic() throws {
    let slangc = try requireSlangc()
    let source = Fixtures.path("GuavaUI/Sources/GuavaUIRuntime/Resources/Shaders/Slang/ui.slang")
    let directory = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for target in ["metal", "spirv"] {
      for stage in ["vertex", "fragment"] {
        let artifact = try compileShader(
          CompileRequest(
            source: source, entry: "ui" + stage.capitalized, stage: stage, target: target,
            output: directory.appendingPathComponent("\(target)-\(stage).json"),
            compiler: slangc, threadgroupSize: nil, lineDirectives: true,
            threadgroupConstants: nil,
            defines: [("UI_VERTEX_SHADER", stage == "vertex" ? "1" : "0")],
            spirvProfile: "spirv_1_5"))
        let interface = artifact["interface"] ?? .object([])
        if stage == "vertex" {
          XCTAssertEqual(try XCTUnwrap(interface["bindings"]), .array([]))
          XCTAssertEqual(
            try XCTUnwrap(interface["pushConstants"]),
            .array([
              .object([("slot", .int(0)), ("byteCount", .int(16)), ("stage", .string("vertex"))])
            ]))
        } else {
          XCTAssertEqual(try XCTUnwrap(interface["pushConstants"]), .array([]))
          let tuples = (interface["bindings"]?.arrayValues ?? []).map {
            "\($0["slot"]?.intValue ?? -1),\($0["space"]?.intValue ?? -1),\($0["type"]?.stringValue ?? "")"
          }
          XCTAssertEqual(tuples, ["1,0,texture", "2,0,sampler"])
        }
      }
    }
  }

  private func assertPreservesArtifact(
    _ fixture: String, entry: String, stage: String,
    dimensions: [Int]? = nil, constants: [Int?]? = nil,
    file: StaticString = #filePath, line: UInt = #line
  ) throws {
    let slangc = try requireSlangc()
    let directory = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("shader.json")
    let reflection = reflectionURL(for: output)
    try Data("previous artifact".utf8).write(to: output)
    try Data("previous reflection".utf8).write(to: reflection)
    let request = CompileRequest(
      source: Fixtures.path("GuavaUI/Runtime/Tests/NativeRHITests/Fixtures/\(fixture).slang"),
      entry: entry, stage: stage, target: "metal", output: output,
      compiler: slangc, threadgroupSize: dimensions, lineDirectives: true,
      threadgroupConstants: constants, defines: nil, spirvProfile: "spirv_1_5")
    XCTAssertThrowsError(try compileShader(request), file: file, line: line)
    XCTAssertEqual(
      try Data(contentsOf: output), Data("previous artifact".utf8), file: file, line: line)
    XCTAssertEqual(
      try Data(contentsOf: reflection), Data("previous reflection".utf8), file: file, line: line)
  }

  func testCompilerFailurePreservesPreviousOutput() throws {
    try assertPreservesArtifact("compute", entry: "absentEntry", stage: "compute")
  }

  func testInconsistentComputeLocalSizePreservesPreviousOutput() throws {
    try assertPreservesArtifact(
      "compute", entry: "computeMain", stage: "compute", dimensions: [1, 1, 1])
  }

  func testMissingMeshLocalSizePreservesPreviousOutput() throws {
    try assertPreservesArtifact("mesh", entry: "meshMain", stage: "mesh")
  }

  func testSpecializedLocalSizeRequiresDeclaredDefaultAndIntegerID() throws {
    try assertPreservesArtifact("specialization", entry: "specializedCompute", stage: "compute")
    let variants: [[Int?]] = [[nil, nil, nil], [3, nil, nil], [4, nil, nil], [0, 1, nil]]
    for constants in variants {
      try assertPreservesArtifact(
        "specialization", entry: "specializedCompute", stage: "compute",
        dimensions: [64, 1, 1], constants: constants)
    }
  }

  func testSpecializedDefaultsAndTypedConstantsSurviveBothTargets() throws {
    let slangc = try requireSlangc()
    let directory = try makeTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for target in ["metal", "spirv"] {
      let artifact = try compileShader(
        CompileRequest(
          source: Fixtures.path("GuavaUI/Runtime/Tests/NativeRHITests/Fixtures/specialization.slang"),
          entry: "specializedCompute", stage: "compute", target: target,
          output: directory.appendingPathComponent("\(target).json"),
          compiler: slangc, threadgroupSize: [37, 1, 1], lineDirectives: true,
          threadgroupConstants: [0, nil, nil], defines: nil, spirvProfile: "spirv_1_5"))
      let interface = artifact["interface"] ?? .object([])
      XCTAssertEqual(
        try XCTUnwrap(interface["threadgroupSize"]),
        .object([("x", .int(37)), ("y", .int(1)), ("z", .int(1))]))
      XCTAssertEqual(
        try XCTUnwrap(interface["threadgroupSpecialization"]),
        .object([("x", .int(0)), ("y", .null), ("z", .null)]))
      let types = Dictionary(
        uniqueKeysWithValues: (interface["specializationConstants"]?.arrayValues ?? []).map {
          ($0["id"]?.intValue ?? -1, $0["type"]?.stringValue ?? "")
        })
      XCTAssertEqual(types[0], "uint32")
      XCTAssertEqual(types[1], "int32")
      XCTAssertEqual(types[2], "float32")
      XCTAssertEqual(types[3], "bool")
    }
  }
}

final class AndroidArtifactTests: XCTestCase {
  func testMobileProgramsUseVulkan11SPIRVWithoutLocalSizeID() throws {
    let directory = Fixtures.path(
      "Engine/Sources/RenderBackend/Resources/Shaders/Native/spirv-mobile")
    let artifacts = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    XCTAssertGreaterThan(artifacts.count, 40)

    func inspect(_ code: String) throws -> [UInt32]? {
      let words = try spvWords(code)
      XCTAssertEqual(words[0], 0x0723_0203)
      XCTAssertLessThanOrEqual(words[1], 0x0001_0300)
      var index = 5
      var local: [UInt32]?
      while index < words.count {
        let count = UInt32(words[index] >> 16)
        let opcode = UInt32(words[index] & 0xffff)
        XCTAssertGreaterThan(count, 0)
        if count == 0 { break }
        if index + 2 < words.count {
          XCTAssertFalse(
            opcode == 331 && words[index + 2] == 38, "LocalSizeId requires maintenance4")
          if opcode == 16 && words[index + 2] == 17, index + 5 < words.count {
            local = Array(words[(index + 3)...(index + 5)])
          }
        }
        index += Int(count)
      }
      return local
    }

    var families = 0
    for file in artifacts {
      let value = try JSONParser.parse(String(contentsOf: file, encoding: .utf8))
      if let variants = value["variants"] {
        families += 1
        let members = variants.objectMembers ?? []
        XCTAssertEqual(Set(members.map { $0.0 }), Set((1...256).map(String.init)))
        for (size, code) in members {
          XCTAssertEqual(try inspect(try XCTUnwrap(code.stringValue)), [UInt32(size) ?? 0, 1, 1])
        }
      } else if let code = value["code"]?.stringValue {
        _ = try inspect(code)
      }
    }
    XCTAssertEqual(families, 7)
  }
}

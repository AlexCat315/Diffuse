internal import Foundation
internal import ToolSupport

/// `prepare` — shared Component fixtures built with the production C API.
enum PrepareOperation {
  struct Fixture {
    var name: String
    var capability: String
    var imports: [String]
  }

  static let fixtures = [
    Fixture(name: "reader", capability: "inspect", imports: []),
    Fixture(name: "scene-query", capability: "inspect", imports: ["guava:scene/query"]),
    Fixture(name: "infinite", capability: "loop", imports: []),
  ]

  /// The authored `.wat` sources live next to the Engine plugin tests.
  static var sourceDirectory: URL {
    Repository.path("Engine/Tests/PluginRuntimeTests/Fixtures")
  }

  static func run(_ arguments: [String]) throws {
    var parser = FlagParser(arguments, valued: ["--probe", "--output"])
    try parser.parse()
    if parser.flags.contains("--help") {
      print(PluginStaging.usage)
      return
    }
    if let unexpected = parser.positionals.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }
    let missing = ["--probe", "--output"].filter { parser.values[$0] == nil }
    guard missing.isEmpty else {
      throw ToolError.message(
        "the following arguments are required: \(missing.joined(separator: ", "))")
    }
    try prepare(
      probe: absolutePath(parser.values["--probe"]!).resolvingSymlinksInPath(),
      output: absolutePath(parser.values["--output"]!))
  }

  static func prepare(probe: URL, output: URL) throws {
    for fixture in fixtures {
      let package = output.appendingPathComponent(fixture.name + ".guavaplugin")
      try Fs.directory(package)
      try Shell.inherit([
        probe.path, "--compile",
        sourceDirectory.appendingPathComponent(fixture.name + ".wat").path,
        package.appendingPathComponent("component.wasm").path,
      ])
      try Fs.write(
        manifest(imports: fixture.imports), to: package.appendingPathComponent("plugin.json"))
      try Fs.write(
        wit(capability: fixture.capability, imports: fixture.imports),
        to: package.appendingPathComponent("capabilities.wit"))
    }
  }

  private struct PluginManifest: Encodable {
    var id = "safe.reader"
    var version = 1
    var name = "Reader"
    var description = "Cross-platform fixture"
    var access = "read"
    var imports: [String]
    var composableHostCapabilities: [String] = []

    private enum CodingKeys: String, CodingKey {
      case id, version, name, description, access, imports
      case composableHostCapabilities = "composable_host_capabilities"
    }
  }

  private static func manifest(imports: [String]) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(decoding: try encoder.encode(PluginManifest(imports: imports)), as: UTF8.self)
  }

  private static func wit(capability: String, imports: [String]) -> String {
    "package safe:reader; interface capabilities { record \(capability)-input { enabled: bool } "
      + "\(capability): func(input: \(capability)-input) -> string; } world plugin { "
      + imports.map { "import \($0);" }.joined()
      + " export capabilities; }"
  }
}

internal import Foundation
internal import ToolSupport

/// `verify` — the portable Component execution/fuel gate for a staged runtime.
enum VerifyOperation {
  static func run(_ arguments: [String]) throws {
    var parser = FlagParser(arguments, valued: ["--probe"])
    try parser.parse()
    if parser.flags.contains("--help") {
      print(PluginStaging.usage)
      return
    }
    if let unexpected = parser.positionals.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }
    guard let probe = parser.values["--probe"] else {
      throw ToolError.message("the following arguments are required: --probe")
    }
    try verify(probe: absolutePath(probe).resolvingSymlinksInPath())
  }

  static func verify(probe: URL) throws {
    let temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("guava-plugin-probe-" + UUID().uuidString)
    try Fs.directory(temporary)
    defer { try? Fs.remove(temporary) }

    try PrepareOperation.prepare(probe: probe, output: temporary)
    let components = PrepareOperation.fixtures.map {
      temporary.appendingPathComponent($0.name + ".guavaplugin/component.wasm").path
    }
    for mode in ["native", "pulley"] {
      try Shell.inherit([probe.path] + components + [mode])
    }
  }
}

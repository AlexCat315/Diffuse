internal import Foundation
internal import ToolSupport

/// `stage` — a pinned Wasmtime runtime independent of the graphics deps.
enum StageOperation {
  static func run(_ arguments: [String]) throws {
    let catalog = try Catalog.read()
    var parser = FlagParser(
      arguments,
      valued: ["--platform", "--vendor", "--cache"],
      switches: ["--check"])
    try parser.parse()
    if parser.flags.contains("--help") {
      print(PluginStaging.usage)
      return
    }
    if let unexpected = parser.positionals.first {
      throw ToolError.message("unrecognized arguments: \(unexpected)")
    }

    let name = try parser.values["--platform"] ?? PluginStaging.host()
    guard let platform = catalog.platforms[name] else {
      let choices = catalog.platforms.keys.sorted().map { "'\($0)'" }.joined(separator: ", ")
      throw ToolError.message(
        "argument --platform: invalid choice: '\(name)' (choose from \(choices))")
    }
    let version = catalog.version
    let vendor = (parser.values["--vendor"].map(absolutePath) ?? Repository.path("Engine/vendor"))
      .resolvingSymlinksInPath()
    let cache =
      (parser.values["--cache"].map(absolutePath) ?? Repository.path("Engine/build/native/wasmtime"))
      .resolvingSymlinksInPath()

    if parser.flags.contains("--check") {
      let checksum = platform.sha256 ?? catalog.sourceSha256
      guard PluginStaging.ready(vendor, name, platform, version, checksum) else {
        throw ToolError.message("Wasmtime \(name) is not staged")
      }
      return
    }

    let base = "https://github.com/bytecodealliance/wasmtime/releases/download/v\(version)"
    let url: String
    let checksum: String
    let installed: URL
    if let release = platform.release {
      let fileExtension = name.hasPrefix("windows-") ? "zip" : "tar.xz"
      url = "\(base)/wasmtime-v\(version)-\(release)-c-api.\(fileExtension)"
      checksum = platform.sha256 ?? catalog.sourceSha256
      installed = try SourceArchive.fetch(url, checksum, cache)
    } else {
      url = "\(base)/wasmtime-v\(version)-src.tar.gz"
      checksum = catalog.sourceSha256
      let source = try SourceArchive.fetch(url, checksum, cache)
      guard let target = platform.rustTarget else {
        throw ToolError.message("Platform \(name) is missing a rust_target for a source build")
      }
      installed = try IOSRuntime.build(source, target, cache)
    }
    try PluginStaging.stage(
      installed, vendor, name, platform, version,
      Provenance.Source(url: url, sha256: checksum))
  }
}

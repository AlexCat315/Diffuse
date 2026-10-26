internal import Foundation
internal import ToolSupport

/// Installs the pinned macOS arm64 Slang toolchain in ignored `Engine/vendor`.
/// Faithful port of `scripts/bootstrap-rhi-slang.py`.
enum BootstrapCommand {
  static let sha256 = "fa46822c92d81404a7951de3746093985c1e6f520f4b533e2aa3bea576f0f2f0"
  static let archiveName = "slang-\(slangVersion)-macos-aarch64.tar.gz"
  static var url: URL {
    URL(
      string:
        "https://github.com/shader-slang/slang/releases/download/v\(slangVersion)/\(archiveName)")!
  }

  static let definitions = [
    ArgumentDefinition(name: "--destination", arity: 1)
  ]

  static func run(_ arguments: [String]) throws {
    let parsed = try ArgumentParser.parse(arguments, definitions: definitions, positionalCount: 0)
    #if !(os(macOS) && arch(arm64))
      throw ToolError.message(
        "This installer targets macOS arm64; set SLANGC to Slang \(slangVersion) on other hosts")
    #else
      let destination =
        parsed.value("--destination").map { URL(fileURLWithPath: $0) }
        ?? Repository.path("Engine/vendor/slang")
      if FileManager.default.fileExists(atPath: destination.path) {
        throw ToolError.message(
          "Destination exists; choose a new --destination to preserve the installed compiler")
      }
      let download = try makeTemporaryDirectory(prefix: "cove-slang-download-")
      defer { try? FileManager.default.removeItem(at: download) }
      let archive = download.appendingPathComponent(archiveName)
      try Download.file(from: url, to: archive, sha256: sha256)

      try Fs.directory(destination.deletingLastPathComponent())
      let staging = try makeTemporaryDirectory(
        prefix: ".slang-install-", in: destination.deletingLastPathComponent())
      defer { try? FileManager.default.removeItem(at: staging) }
      let installed = staging.appendingPathComponent("toolchain")
      try Fs.directory(installed)
      try Archive.extract(archive, to: installed)
      let installedVersion = try runTool([
        installed.appendingPathComponent("bin/slangc").path, "-version",
      ])
      guard installedVersion == slangVersion else {
        throw ToolError.message("Expected Slang \(slangVersion), got '\(installedVersion)'")
      }
      try FileManager.default.moveItem(at: installed, to: destination)
      Terminal.info(destination.resolvingSymlinksInPath().appendingPathComponent("bin/slangc").path)
    #endif
  }
}

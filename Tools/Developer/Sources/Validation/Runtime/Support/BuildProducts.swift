internal import Foundation
internal import ToolSupport

/// Locates the debug products the editor validations drive, preferring the
/// Xcode `Products` directory and falling back to SwiftPM's `.build/debug`
/// layout exactly as the Python and JavaScript originals did.
enum BuildProducts {
  static func isFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
  }

  static func executable(package: String, name: String, configuration: String = "debug") throws
    -> URL
  {
    let product = configuration.prefix(1).uppercased() + configuration.dropFirst()
    let root = Repository.root
    let candidates = [
      root.appendingPathComponent("\(package)/.build/out/Products/\(product)/\(name)"),
      root.appendingPathComponent("\(package)/.build/\(configuration)/\(name)"),
    ]
    guard let found = candidates.first(where: isFile) else {
      throw ToolError.message("Build \(package)'s \(name) before running this validation")
    }
    return found.resolvingSymlinksInPath()
  }

  /// The stdio MCP server exercised by the protocol and Crystal Rush checks.
  /// `DIFFUSE_MCP_EXECUTABLE` replaces the built candidates when set.
  static func mcpServer() throws -> URL {
    let root = Repository.root
    let candidates: [URL]
    if let override = ProcessInfo.processInfo.environment["DIFFUSE_MCP_EXECUTABLE"], !override.isEmpty
    {
      candidates = [URL(fileURLWithPath: override)]
    } else {
      candidates = [
        root.appendingPathComponent("DiffuseMCP/.build/out/Products/Debug/DiffuseMCP"),
        root.appendingPathComponent("DiffuseMCP/.build/debug/DiffuseMCP"),
      ]
    }
    guard let found = candidates.first(where: isFile) else {
      throw ToolError.message("Build DiffuseMCP's DiffuseMCP first, or set DIFFUSE_MCP_EXECUTABLE")
    }
    return found
  }
}

internal import Foundation
internal import ToolSupport

/// Builds pinned native Vulkan headers and loader for Windows or Linux hosts.
///
/// Replaces `scripts/bootstrap-rhi-vulkan.py`. This builds SDK libraries, not a
/// GPU driver; point `VULKAN_SDK` at the resulting destination. macOS uses
/// Metal and needs no Vulkan dependency.
public enum VulkanBootstrap {
  static let version = "1.4.328"

  /// Pinned source archives, verified before extraction.
  static let digests: [(name: String, sha256: String)] = [
    ("Vulkan-Headers", "3ad56d387179b47dd632432ccf989bbb69773e1d732692b7bbad9c4d36aa1304"),
    ("Vulkan-Loader", "07b5bae70dabdd2ee5a0fdaea95f72dac9561ddd768b0739d4af6cb8771e9ac8"),
  ]

  static let usage = """
    guava task vulkan -- bootstrap [--destination PATH]

      --destination PATH  Defaults to Engine/vendor/vulkan-sdk; the path must not exist.
    """

  public static func run(_ arguments: [String]) throws {
    guard let operation = arguments.first else {
      throw ToolError.message("Missing operation; expected bootstrap")
    }
    switch operation {
    case "bootstrap": try Bootstrap.run(Array(arguments.dropFirst()))
    case "-h", "--help": print(usage)
    default: throw ToolError.message("Unknown operation '\(operation)'; expected bootstrap")
    }
  }
}

/// Makes a possibly relative command-line path absolute against the caller's
/// working directory, matching `pathlib.Path(...)`.
func absolutePath(_ path: String) -> URL {
  if (path as NSString).isAbsolutePath { return URL(fileURLWithPath: path).standardizedFileURL }
  return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent(path)
    .standardizedFileURL
}

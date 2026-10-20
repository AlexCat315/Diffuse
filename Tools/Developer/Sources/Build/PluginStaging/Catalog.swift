internal import Foundation
internal import ToolSupport

#if canImport(Darwin)
  private import Darwin
#elseif canImport(Glibc)
  private import Glibc
#endif

/// One pinned platform catalog shared by standalone and build-system staging.
/// Reads `Engine/third-party/wasmtime/catalog.json`.
struct Catalog: Decodable {
  struct Platform: Decodable {
    var release: String?
    var rustTarget: String?
    var triple: String
    var sha256: String?

    init(release: String? = nil, rustTarget: String? = nil, triple: String, sha256: String? = nil) {
      self.release = release
      self.rustTarget = rustTarget
      self.triple = triple
      self.sha256 = sha256
    }

    private enum CodingKeys: String, CodingKey {
      case release
      case rustTarget = "rust_target"
      case triple
      case sha256
    }
  }

  var version: String
  var sourceSha256: String
  var platforms: [String: Platform]

  private enum CodingKeys: String, CodingKey {
    case version
    case sourceSha256 = "source_sha256"
    case platforms
  }

  static var location: URL { Repository.path("Engine/third-party/wasmtime/catalog.json") }

  static func read() throws -> Catalog {
    try JSONDecoder().decode(Catalog.self, from: try Fs.read(location))
  }
}

extension PluginStaging {
  /// Maps the host architecture and OS onto a catalog platform key.
  static func host() throws -> String {
    let architecture = machine().lowercased()
    guard ["arm64", "aarch64", "x86_64", "amd64"].contains(architecture) else {
      throw ToolError.message("Unsupported native architecture: \(architecture)")
    }
    let arm = architecture == "arm64" || architecture == "aarch64"
    #if os(macOS)
      return arm ? "macos-arm64" : "macos-x86_64"
    #elseif os(Windows)
      return arm ? "windows-arm64" : "windows-x86_64"
    #elseif os(Linux)
      return arm ? "linux-aarch64" : "linux-x86_64"
    #else
      throw ToolError.message("Specify a supported --platform for this host")
    #endif
  }

  private static func machine() -> String {
    #if os(Windows)
      return ProcessInfo.processInfo.environment["PROCESSOR_ARCHITECTURE"] ?? ""
    #else
      var info = utsname()
      guard uname(&info) == 0 else { return "" }
      return withUnsafeBytes(of: info.machine) { raw in
        String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
      }
    #endif
  }
}

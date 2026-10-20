internal import Foundation
internal import ToolSupport

/// The SwiftPM artifact bundle manifest written under
/// `FFmpeg.artifactbundle/info.json`.
struct ArtifactBundle: Codable {
  struct Variant: Codable {
    struct StaticLibraryMetadata: Codable {
      var headerPaths: [String]
    }

    var path: String
    var supportedTriples: [String]
    var staticLibraryMetadata: StaticLibraryMetadata
  }

  struct Artifact: Codable {
    var type: String
    var version: String
    var variants: [Variant]
  }

  var schemaVersion: String
  var artifacts: [String: Artifact]
}

/// Per-variant provenance recorded next to the staged files so integrity can be
/// re-checked without network access.
struct Provenance: Codable {
  var version: String
  var sourceSha256: String
  var license: String
  /// Variant-relative path to SHA-256, excluding the stamp itself.
  var files: [String: String]

  private enum CodingKeys: String, CodingKey {
    case version
    case sourceSha256 = "source_sha256"
    case license
    case files
  }
}

extension StageOperation {
  /// `shutil.copytree(source, destination, dirs_exist_ok=True)`: copies a tree
  /// over an existing destination, replacing files but leaving unrelated
  /// entries in place.
  static func merge(_ source: URL, into destination: URL) throws {
    for entry in try Fs.files(in: source, includeDirectories: true) {
      let target = destination.appendingPathComponent(Fs.relative(entry, to: source))
      if try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
        try Fs.directory(target)
      } else {
        try Fs.copy(entry, to: target)
      }
    }
  }
}

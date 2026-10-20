internal import Foundation
internal import ToolSupport

/// The SwiftPM artifact bundle manifest written under
/// `Wasmtime.artifactbundle/info.json`.
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
  struct Source: Codable {
    var url: String
    var sha256: String
  }

  var version: String
  var source: Source
  var sha256: String
  var files: [String: String]
  var linkage: String
  var execution: String
}

extension PluginStaging {
  /// Stages one platform variant. Other variants already present in the
  /// bundle are preserved; the swap is transactional.
  static func stage(
    _ installed: URL, _ vendor: URL, _ name: String,
    _ platform: Catalog.Platform, _ version: String,
    _ source: Provenance.Source
  ) throws {
    try withStagingLock(vendor) {
      try stageLocked(installed, vendor, name, platform, version, source)
    }
  }

  /// Whether the staged variant matches the catalog version, provenance and
  /// recorded file digests.
  static func ready(
    _ vendor: URL, _ name: String, _ platform: Catalog.Platform,
    _ version: String, _ sourceChecksum: String
  ) -> Bool {
    do {
      let bundle = vendor.appendingPathComponent("Wasmtime.artifactbundle")
      let info = try JSONDecoder().decode(
        ArtifactBundle.self,
        from: try Data(contentsOf: bundle.appendingPathComponent("info.json")))
      guard let artifact = info.artifacts["Wasmtime"] else { return false }
      let provenance = try JSONDecoder().decode(
        Provenance.self,
        from: try Data(
          contentsOf: bundle.appendingPathComponent(name).appendingPathComponent("provenance.json"))
      )
      guard
        let variant = artifact.variants.first(where: {
          $0.supportedTriples.contains(platform.triple)
        })
      else {
        return false
      }
      let files = provenance.files
      let variantDirectory = bundle.appendingPathComponent(name)
      return artifact.version == version
        && provenance.version == version
        && provenance.source.sha256 == sourceChecksum
        && variant.path.hasPrefix(name + "/lib/")
        && provenance.execution == (name.hasPrefix("ios-") ? "pulley" : "native-or-pulley")
        && !files.isEmpty
        && files["include/wasmtime.h"] != nil
        && files.allSatisfy { path, checksum in
          (try? SHA256.hex(file: variantDirectory.appendingPathComponent(path))) == checksum
        }
    } catch {
      return false
    }
  }

  private static func stageLocked(
    _ installed: URL, _ vendor: URL, _ name: String,
    _ platform: Catalog.Platform, _ version: String,
    _ source: Provenance.Source
  ) throws {
    let bundle = vendor.appendingPathComponent("Wasmtime.artifactbundle")
    try Fs.directory(bundle)
    let manifest = bundle.appendingPathComponent("info.json")

    var info = ArtifactBundle(schemaVersion: "1.0", artifacts: [:])
    if FileManager.default.fileExists(atPath: manifest.path) {
      info = try JSONDecoder().decode(ArtifactBundle.self, from: try Data(contentsOf: manifest))
    }
    var artifact =
      info.artifacts["Wasmtime"]
      ?? ArtifactBundle.Artifact(type: "staticLibrary", version: version, variants: [])
    guard artifact.version == version else {
      throw ToolError.message("Remove the old Wasmtime artifact bundle before changing versions")
    }

    let libraryName = name.hasPrefix("windows-") ? "wasmtime.lib" : "libwasmtime.a"
    let relativeLibrary = "lib/" + libraryName
    let execution = name.hasPrefix("ios-") ? "pulley" : "native-or-pulley"

    let directory = bundle.appendingPathComponent(".stage-" + UUID().uuidString)
    try Fs.directory(directory)
    defer { try? Fs.remove(directory) }
    let candidate = directory.appendingPathComponent(name)
    try Fs.copyTree(
      installed.appendingPathComponent("include"), to: candidate.appendingPathComponent("include"))
    try Fs.directory(candidate.appendingPathComponent("lib"))
    try Fs.copy(
      installed.appendingPathComponent("lib").appendingPathComponent(libraryName),
      to: candidate.appendingPathComponent(relativeLibrary))

    var files: [String: String] = [:]
    for file in try Fs.files(in: candidate) {
      files[Fs.relative(file, to: candidate)] = try SHA256.hex(file: file)
    }
    guard let libraryDigest = files[relativeLibrary] else {
      throw ToolError.message("Staged library missing from archive layout: \(relativeLibrary)")
    }
    let provenance = Provenance(
      version: version, source: source, sha256: libraryDigest,
      files: files, linkage: "static", execution: execution)
    try Fs.json(provenance, to: candidate.appendingPathComponent("provenance.json"))
    try Fs.copy(
      installed.appendingPathComponent("LICENSE"), to: bundle.appendingPathComponent("LICENSE"))

    artifact.variants = artifact.variants.filter { !$0.supportedTriples.contains(platform.triple) }
    artifact.variants.append(
      ArtifactBundle.Variant(
        path: "\(name)/\(relativeLibrary)",
        supportedTriples: [platform.triple],
        staticLibraryMetadata: .init(headerPaths: ["\(name)/include"])))
    artifact.variants.sort { $0.path < $1.path }
    info.artifacts["Wasmtime"] = artifact

    let temporary = bundle.appendingPathComponent("info.tmp")
    try Fs.json(info, to: temporary)

    let variant = bundle.appendingPathComponent(name)
    let backup = bundle.appendingPathComponent(
      ".previous-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
    let existed = FileManager.default.fileExists(atPath: variant.path)
    if existed { try FileManager.default.moveItem(at: variant, to: backup) }
    do {
      try FileManager.default.moveItem(at: candidate, to: variant)
      try Fs.replace(temporary, at: manifest)
    } catch {
      try? Fs.remove(variant)
      if existed { try? FileManager.default.moveItem(at: backup, to: variant) }
      throw error
    }
    try? Fs.remove(backup)

    // Remove only files owned by the replaced dynamic integration.
    try? Fs.remove(vendor.appendingPathComponent("Wasmtime.xcframework"))
    for old in ["Wasmtime-build-manifest.json", "Wasmtime-LICENSE"] {
      try? Fs.remove(vendor.appendingPathComponent(old))
    }
    print("Staged Wasmtime \(version): \(name) (\(execution))")
  }

  /// A directory lock so concurrent staging runs never interleave their
  /// bundle mutations.
  private static func withStagingLock<T>(_ vendor: URL, _ body: () throws -> T) throws -> T {
    try Fs.directory(vendor)
    let lock = vendor.appendingPathComponent(".wasmtime-staging.lock")
    let deadline = Date().addingTimeInterval(30)
    while true {
      do {
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        break
      } catch {
        guard FileManager.default.fileExists(atPath: lock.path) else { throw error }
        guard Date() <= deadline else {
          throw ToolError.message("Wasmtime staging is locked: \(lock.path)")
        }
        Thread.sleep(forTimeInterval: 0.2)
      }
    }
    defer { try? Fs.remove(lock) }
    return try body()
  }
}

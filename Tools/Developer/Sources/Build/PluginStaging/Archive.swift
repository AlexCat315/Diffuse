internal import Foundation
internal import ToolSupport

/// Verified upstream downloads. Never execute code from an unverified archive.
enum SourceArchive {
  static func fetch(_ url: String, _ checksum: String, _ cache: URL) throws -> URL {
    try Fs.directory(cache)
    guard let remote = URL(string: url) else {
      throw ToolError.message("Invalid archive URL: \(url)")
    }
    let archive = cache.appendingPathComponent(String(url.split(separator: "/").last ?? ""))
    try Download.file(from: remote, to: archive, sha256: checksum)

    var name = archive.lastPathComponent
    for suffix in [".tar.xz", ".tar.gz", ".zip"] where name.hasSuffix(suffix) {
      name = String(name.dropLast(suffix.count))
      break
    }
    let destination = cache.appendingPathComponent(name)
    let marker = destination.appendingPathComponent(".extracted")
    if !FileManager.default.fileExists(atPath: marker.path) {
      try Fs.directory(destination)
      try Shell.inherit(
        ["cmake", "-E", "tar", "xf", archive.standardizedFileURL.path], at: destination)
      try Fs.write("", to: marker)
    }
    let roots = try FileManager.default
      .contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey])
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    guard roots.count == 1, let root = roots.first else {
      throw ToolError.message("Unexpected upstream archive layout: \(archive.path)")
    }
    return root
  }
}

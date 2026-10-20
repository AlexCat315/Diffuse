package import Foundation

/// Archive extraction delegates to the platform tar, which understands the
/// xz/gz formats the pinned toolchains ship in on every supported host.
package enum Archive {
  package static func extract(_ archive: URL, to destination: URL, stripComponents: Int = 0) throws
  {
    guard FileManager.default.fileExists(atPath: archive.path) else {
      throw ToolError.message("Archive not found: \(archive.path)")
    }
    try Fs.directory(destination)
    var arguments: [String]
    #if os(Windows)
      // MSYS2's GNU tar treats a `-f` path of the form `C:/…` as a remote
      // host (`C:`) and dies with "Cannot connect to C: resolve failed".
      // `--force-local` tells it to read the archive as a local file.
      arguments = ["tar", "--force-local", "-xf", archive.path, "-C", destination.path]
    #else
      arguments = ["tar", "-xf", archive.path, "-C", destination.path]
    #endif
    if stripComponents > 0 { arguments += ["--strip-components", String(stripComponents)] }
    try Shell.inherit(arguments)
  }
}

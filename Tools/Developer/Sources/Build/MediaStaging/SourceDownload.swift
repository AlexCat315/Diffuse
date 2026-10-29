internal import Foundation
internal import ToolSupport

/// Keep source downloads bounded, retryable, checksum verified and resilient to
/// an unreachable upstream: each mirror is tried in order, and a `file://` URL
/// (the vendored in-repo source) lets CI build without touching the network.
enum SourceDownload {
  /// Fetch the FFmpeg source from the first reachable `mirrors` entry whose
  /// download verifies against `sha256`. `https` and `file` schemes are
  /// accepted; `file` URLs copy a local archive (used for the vendored source
  /// so a flaky or blocked `ffmpeg.org` can never stall a release).
  static func fetch(
    from mirrors: [URL], to destination: URL, sha256: String,
    environment: [String: String],
    transfer: ([String], [String: String]) throws -> Void = { command, environment in
      try Shell.inherit(command, environment: environment)
    }
  ) throws {
    if let actual = try? SHA256.hex(file: destination),
       actual.caseInsensitiveCompare(sha256) == .orderedSame { return }
    var lastError: Error?
    for mirror in mirrors {
      do {
        try fetchOnce(from: mirror, to: destination, sha256: sha256, environment: environment, transfer: transfer)
        return
      } catch {
        lastError = error
        Terminal.info("FFmpeg source mirror unavailable (\(mirror.absoluteString)); trying next")
      }
    }
    throw lastError
      ?? ToolError.message("No FFmpeg source mirrors were configured")
  }

  private static func fetchOnce(
    from remote: URL, to destination: URL, sha256: String,
    environment: [String: String],
    transfer: ([String], [String: String]) throws -> Void
  ) throws {
    try Fs.directory(destination.deletingLastPathComponent())
    let staging = destination.deletingLastPathComponent().appendingPathComponent(
      ".ffmpeg-download-\(UUID().uuidString)")
    defer { try? Fs.remove(staging) }

    if remote.scheme == "file" {
      Terminal.info("Using vendored FFmpeg source \(remote.path)")
      try Fs.copy(URL(fileURLWithPath: remote.path), to: staging)
    } else {
      guard remote.scheme == "https" else {
        throw ToolError.message("FFmpeg source requires HTTPS or a file:// URL")
      }
      guard let curl = Shell.executable("curl", environment: environment) else {
        throw ToolError.message("curl is required to download FFmpeg sources")
      }
      Terminal.info("Downloading \(remote.absoluteString)")
      try transfer([
        curl.path, "--fail", "--show-error", "--location",
        "--proto", "=https", "--proto-redir", "=https",
        "--connect-timeout", "20", "--max-time", "180",
        "--retry", "4", "--retry-all-errors", "--retry-delay", "2", "--retry-max-time", "600",
        "--output", staging.path, remote.absoluteString,
      ], environment)
    }
    try Download.verify(file: staging, sha256: sha256)
    try Fs.replace(staging, at: destination)
  }
}

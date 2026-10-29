internal import Foundation
internal import ToolSupport

/// Keep source downloads bounded, retryable and checksum verified on every host.
enum SourceDownload {
  typealias Transfer = ([String], [String: String]) throws -> Void

  static func fetch(
    from remote: URL, to destination: URL, sha256: String,
    environment: [String: String],
    transfer: Transfer = { command, environment in try Shell.inherit(command, environment: environment) }
  ) throws {
    try fetch(from: [remote], to: destination, sha256: sha256, environment: environment, transfer: transfer)
  }

  static func fetch(
    from remotes: [URL], to destination: URL, sha256: String,
    environment: [String: String],
    transfer: Transfer = { command, environment in try Shell.inherit(command, environment: environment) }
  ) throws {
    guard !remotes.isEmpty, remotes.allSatisfy({ $0.scheme == "https" }) else {
      throw ToolError.message("FFmpeg sources require HTTPS mirrors")
    }
    if let actual = try? SHA256.hex(file: destination),
       actual.caseInsensitiveCompare(sha256) == .orderedSame { return }
    guard let curl = Shell.executable("curl", environment: environment) else {
      throw ToolError.message("curl is required to download FFmpeg sources")
    }
    try Fs.directory(destination.deletingLastPathComponent())
    var failures: [String] = []
    for remote in remotes {
      let staging = destination.deletingLastPathComponent().appendingPathComponent(
        ".ffmpeg-download-\(UUID().uuidString)")
      defer { try? Fs.remove(staging) }
      Terminal.info("Downloading \(remote.absoluteString)")
      do {
        try transfer([
          curl.path, "--fail", "--show-error", "--location", "--ipv4",
          "--proto", "=https", "--proto-redir", "=https",
          "--connect-timeout", "20", "--max-time", "180",
          "--retry", "4", "--retry-all-errors", "--retry-delay", "2", "--retry-max-time", "600",
          "--output", staging.path, remote.absoluteString,
        ], environment)
        try Download.verify(file: staging, sha256: sha256)
        try Fs.replace(staging, at: destination)
        return
      } catch {
        failures.append("\(remote.absoluteString): \(error)")
      }
    }
    throw ToolError.message("FFmpeg source download failed from every mirror:\n" + failures.joined(separator: "\n"))
  }
}

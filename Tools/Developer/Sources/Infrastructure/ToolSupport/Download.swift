package import Foundation

#if canImport(FoundationNetworking)
  internal import FoundationNetworking
#endif

/// Downloads a pinned artifact and verifies its SHA-256 before use. A cached
/// file that already matches the digest is reused without network access.
package enum Download {
  package static func verify(file url: URL, sha256 expected: String) throws {
    let actual = try SHA256.hex(file: url)
    guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
      throw ToolError.message(
        "SHA-256 mismatch for \(url.lastPathComponent): expected \(expected), got \(actual)")
    }
  }

  package static func file(from remote: URL, to destination: URL, sha256: String) throws {
    if FileManager.default.fileExists(atPath: destination.path) {
      if let actual = try? SHA256.hex(file: destination),
        actual.caseInsensitiveCompare(sha256) == .orderedSame
      {
        return
      }
      try Fs.remove(destination)
    }
    try Fs.directory(destination.deletingLastPathComponent())
    Terminal.info("Downloading \(remote.absoluteString)")
    let downloaded = try fetch(remote)
    defer { try? Fs.remove(downloaded) }
    try verify(file: downloaded, sha256: sha256)
    try Fs.replace(downloaded, at: destination)
  }

  private static func fetch(_ remote: URL) throws -> URL {
    let semaphore = DispatchSemaphore(value: 0)
    let result = UncheckedBox<Result<URL, Error>>()
    let task = URLSession.shared.downloadTask(with: remote) { location, response, error in
      defer { semaphore.signal() }
      if let error {
        result.set(.failure(error))
        return
      }
      if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        result.set(
          .failure(ToolError.message("HTTP \(http.statusCode) for \(remote.absoluteString)")))
        return
      }
      guard let location else {
        result.set(.failure(ToolError.message("No data for \(remote.absoluteString)")))
        return
      }
      let staging = FileManager.default.temporaryDirectory.appendingPathComponent(
        "guava-download-\(UUID().uuidString)")
      do {
        try FileManager.default.moveItem(at: location, to: staging)
        result.set(.success(staging))
      } catch {
        result.set(.failure(error))
      }
    }
    task.resume()
    semaphore.wait()
    switch result.get() {
    case .success(let url): return url
    case .failure(let error): throw error
    case nil: throw ToolError.message("Download did not complete: \(remote.absoluteString)")
    }
  }
}

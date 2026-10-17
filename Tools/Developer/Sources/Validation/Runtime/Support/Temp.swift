internal import Foundation
internal import ToolSupport

/// Temporary-directory creation and log-file access shared by the editor
/// validations.
enum Temp {
  /// Mirror of `tempfile.mkdtemp(prefix:)`: a fresh directory the caller
  /// owns and may keep, as `validate-editor-native-loop.py` did.
  static func directory(prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent(prefix + UUID().uuidString.lowercased())
    try Fs.directory(url)
    return url
  }
}

/// Opens (creating or truncating) a file that a child process writes to. The
/// Python originals passed `log.open("wb")` straight to `subprocess.Popen`.
func openForWriting(_ url: URL) throws -> FileHandle {
  try Fs.directory(url.deletingLastPathComponent())
  FileManager.default.createFile(atPath: url.path, contents: nil)
  return try FileHandle(forWritingTo: url)
}

/// Reads a child's log back as text, tolerating a write in progress.
func readText(_ url: URL) throws -> String {
  guard let data = try? Data(contentsOf: url) else { return "" }
  return String(decoding: data, as: UTF8.self)
}

/// The Python `text[-8192:]` tails used in failure messages.
func tail(_ text: String, _ count: Int = 8192) -> String {
  text.count <= count ? text : String(text.suffix(count))
}

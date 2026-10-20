package import Foundation

package enum Fs {
  package static func directory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  package static func remove(_ url: URL) throws {
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  package static func reset(_ url: URL) throws {
    try remove(url)
    try directory(url)
  }

  package static func copy(_ source: URL, to destination: URL) throws {
    try directory(destination.deletingLastPathComponent())
    try remove(destination)
    try FileManager.default.copyItem(at: source, to: destination)
  }

  package static func copyTree(_ source: URL, to destination: URL) throws {
    try directory(destination.deletingLastPathComponent())
    try remove(destination)
    try FileManager.default.copyItem(at: source, to: destination)
  }

  package static func read(_ url: URL) throws -> Data { try Data(contentsOf: url) }
  package static func text(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
  }

  package static func write(_ text: String, to url: URL) throws {
    try directory(url.deletingLastPathComponent())
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  package static func write(_ data: Data, to url: URL) throws {
    try directory(url.deletingLastPathComponent())
    try data.write(to: url, options: .atomic)
  }

  package static func json<T: Encodable>(_ value: T, to url: URL, pretty: Bool = true) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting =
      pretty
      ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
      : [.sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(value)
    data.append(0x0A)
    try write(data, to: url)
  }

  package static func files(in directory: URL, includeDirectories: Bool = false) throws -> [URL] {
    var failure: Error?
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory,
        includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
        errorHandler: { _, error in
          failure = error
          return false
        })
    else {
      throw ToolError.message("Cannot read \(directory.path)")
    }
    var result: [URL] = []
    for case let entry as URL in enumerator {
      let values = try entry.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
      if includeDirectories, values.isDirectory == true {
        result.append(entry)
      } else if values.isRegularFile == true {
        result.append(entry)
      }
    }
    if let failure { throw failure }
    return result.sorted { $0.path < $1.path }
  }

  /// Relative path using forward slashes, matching archive and manifest conventions.
  package static func relative(_ file: URL, to root: URL) -> String {
    let components = file.standardizedFileURL.pathComponents
    let base = root.standardizedFileURL.pathComponents
    var common = 0
    while common < min(components.count, base.count), components[common] == base[common] {
      common += 1
    }
    return
      (Array(repeating: "..", count: base.count - common) + Array(components.dropFirst(common)))
      .joined(separator: "/")
  }

  /// Atomically publishes a staged file, matching "write temp then replace" semantics.
  package static func replace(_ staged: URL, at destination: URL) throws {
    try directory(destination.deletingLastPathComponent())
    // `FileManager.replaceItemAt` traps on Windows ("not yet implemented" in
    // corelibs-foundation), so publish with an explicit remove + move there.
    #if os(Windows)
      try remove(destination)
      try FileManager.default.moveItem(at: staged, to: destination)
    #else
      if FileManager.default.fileExists(atPath: destination.path) {
        _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
      } else {
        try FileManager.default.moveItem(at: staged, to: destination)
      }
    #endif
  }
}

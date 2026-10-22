import Foundation

/// The project's files in the served language, and the file names its plugin
/// watches (such as a package manifest), by modification date, so
/// edits made outside the editor (a checkout, a generator, another editor)
/// reach the language server as `workspace/didChangeWatchedFiles`.
struct ScriptWatchedFiles: Sendable, Equatable {
    /// LSP `FileChangeType`.
    enum ChangeType: Int, Sendable { case created = 1, changed = 2, deleted = 3 }
    struct Change: Sendable, Equatable {
        let url: URL
        let type: ChangeType
    }

    private var entries: [URL: Date] = [:]
    /// A folder this large is scanned no further, keeping each poll cheap.
    private static let limit = 20_000
    private static let skipped: Set<String> = ["node_modules", "DerivedData", "Pods", "Carthage"]

    static func scan(_ root: URL, extensions: Set<String>, names: Set<String>) -> Self {
        var result = Self()
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return result }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > limit { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if skipped.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            guard extensions.contains(url.pathExtension) || names.contains(url.lastPathComponent) else { continue }
            result.entries[url.standardizedFileURL] = values?.contentModificationDate ?? .distantPast
        }
        return result
    }

    /// Whether `root` holds any file with one of `extensions`, stopping at the first.
    static func contains(_ root: URL, extensions: Set<String>) -> Bool {
        guard !extensions.isEmpty, let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return false }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > limit { return false }
            if skipped.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            if extensions.contains(url.pathExtension) { return true }
        }
        return false
    }

    func changes(to next: Self) -> [Change] {
        var changes: [Change] = []
        for (url, date) in next.entries {
            if let previous = entries[url] {
                if previous != date { changes.append(Change(url: url, type: .changed)) }
            } else {
                changes.append(Change(url: url, type: .created))
            }
        }
        for url in entries.keys where next.entries[url] == nil { changes.append(Change(url: url, type: .deleted)) }
        return changes.sorted { $0.url.path < $1.url.path }
    }
}

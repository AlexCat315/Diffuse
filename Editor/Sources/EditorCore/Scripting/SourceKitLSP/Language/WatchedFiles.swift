import Foundation

/// The project's Swift sources and package files by modification date, so
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

    static func scan(_ root: URL) -> Self {
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
            guard url.pathExtension == "swift" || url.lastPathComponent == "Package.resolved" else { continue }
            result.entries[url.standardizedFileURL] = values?.contentModificationDate ?? .distantPast
        }
        return result
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

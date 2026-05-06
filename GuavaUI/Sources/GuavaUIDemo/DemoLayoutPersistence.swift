import Foundation
import GuavaUIWorkspace

/// Disk persistence for the demo's `WorkspaceController` layout.
///
/// File path: `~/.guava/workspace-demo.json`. The directory is created on first
/// save. Reads return `nil` when the file is missing or corrupt — callers
/// should fall back to the built-in default layout.
enum DemoLayoutPersistence {
    static var path: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("workspace-demo.json", isDirectory: false)
    }

    static func save(_ document: WorkspaceDocument) throws {
        let url = path
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
    }

    static func load() -> WorkspaceDocument? {
        let url = path
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(WorkspaceDocument.self, from: data)
    }

    @discardableResult
    static func delete() -> Bool {
        let url = path
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}

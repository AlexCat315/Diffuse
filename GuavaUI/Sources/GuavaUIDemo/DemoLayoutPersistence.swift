import Foundation
import GuavaUICompose

/// Disk persistence for the demo's `DockController` layout.
///
/// File path: `~/.guava/dock-demo.json`. The directory is created on first
/// save. Reads return `nil` when the file is missing or corrupt — callers
/// should fall back to the built-in default layout.
enum DemoLayoutPersistence {
    static var path: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("dock-demo.json", isDirectory: false)
    }

    static func save(_ snapshot: DockLayoutSnapshot) throws {
        let url = path
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    static func load() -> DockLayoutSnapshot? {
        let url = path
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? JSONDecoder().decode(DockLayoutSnapshot.self, from: data)
    }

    @discardableResult
    static func delete() -> Bool {
        let url = path
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}

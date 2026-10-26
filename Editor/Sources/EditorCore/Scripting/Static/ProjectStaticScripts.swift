private import CoveFileSystem
import Foundation

/// Host build input for APKs. The sources are compiled into the player and are not shipped as assets.
public struct ProjectStaticScripts: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public let identifier: String
        public let displayName: String
        public let source: String
    }
    public static let relativePath = ".cove/static-scripts.json"
    public let entries: [Entry]

    static func stage(_ assets: [ResolvedScriptAsset], in directory: URL) throws -> Set<String> {
        let fileManager = FileManager.default
        let sources = directory.appendingPathComponent(".cove/static-sources", isDirectory: true)
        try fileManager.createDirectory(at: sources, withIntermediateDirectories: true)
        let entries = try assets.map { asset in
            let relative = ".cove/static-sources/\(asset.id.rawValue).swift"
            try fileManager.copyItem(at: asset.url, to: directory.appendingPathComponent(relative))
            return Entry(identifier: asset.id.runtimeIdentifier,
                         displayName: asset.url.deletingPathExtension().lastPathComponent, source: relative)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(encoder.encode(Self(entries: entries)), to: directory.appendingPathComponent(relativePath))
        return Set(entries.map(\.identifier))
    }
}

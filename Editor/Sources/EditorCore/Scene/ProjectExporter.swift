import Foundation

/// Metadata describing a portable project export bundle.
public struct ProjectExportDescriptor: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var appName: String
    public var exportedAt: String
    public var entityCount: Int
    public var assetCount: Int
    /// Save slot the scene was written to — the slot GuavaPlayer's project loader reads.
    public var sceneSlot: Int

    public init(schemaVersion: Int, appName: String, exportedAt: String,
                entityCount: Int, assetCount: Int, sceneSlot: Int) {
        self.schemaVersion = schemaVersion
        self.appName = appName
        self.exportedAt = exportedAt
        self.entityCount = entityCount
        self.assetCount = assetCount
        self.sceneSlot = sceneSlot
    }
}

/// A referenced asset recorded in the export (paths stay project-relative).
public struct ProjectExportAsset: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var relativePath: String
    public var kind: String
    public var meshIndex: Int
}

public struct ProjectExportAssetList: Codable, Sendable, Equatable {
    public var assets: [ProjectExportAsset]
}

/// Writes a self-contained, platform-agnostic project export bundle. The layout is exactly
/// what `GuavaPlayer --project <dir>` expects to load, so the bundle is immediately runnable:
///
///     build.json                     descriptor / metadata
///     assets.json                    referenced asset list
///     .guava/game-saves/slot-0.json  scene captured as a GameSaveDocument
///
/// This is the data half of "build" — codesigned `.app` packaging is a separate, platform
/// specific step layered on top of this bundle.
public enum ProjectExporter {
    public static let schemaVersion = 1
    public static let sceneSlot = 0

    @discardableResult
    public static func export(manifest: EditorSceneManifest,
                              appName: String,
                              assets: [EditorAsset] = [],
                              to outputDirectory: URL) throws -> ProjectExportDescriptor {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        // Scene → GameSaveDocument at slot 0: the exact format GameApplication loads.
        let save = GameSaveDocument(slot: sceneSlot, manifest: manifest)
        try save.write(to: GameSaveDocument.url(slot: sceneSlot, projectDirectory: outputDirectory.path))

        let assetList = ProjectExportAssetList(assets: assets.map {
            ProjectExportAsset(id: $0.id, name: $0.name, relativePath: $0.relativePath,
                               kind: $0.kind.rawValue, meshIndex: $0.meshIndex)
        })
        try writeJSON(assetList, to: outputDirectory.appendingPathComponent("assets.json"))

        let descriptor = ProjectExportDescriptor(
            schemaVersion: schemaVersion,
            appName: appName,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            entityCount: manifest.entityCount,
            assetCount: assets.count,
            sceneSlot: sceneSlot
        )
        try writeJSON(descriptor, to: outputDirectory.appendingPathComponent("build.json"))
        return descriptor
    }

    /// Reads back a previously written descriptor (used to validate or inspect a bundle).
    public static func readDescriptor(from outputDirectory: URL) throws -> ProjectExportDescriptor {
        let data = try Data(contentsOf: outputDirectory.appendingPathComponent("build.json"))
        return try JSONDecoder().decode(ProjectExportDescriptor.self, from: data)
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }
}

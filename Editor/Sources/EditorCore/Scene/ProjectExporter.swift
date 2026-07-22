import Foundation

public enum ProjectExporterError: Error, CustomStringConvertible, Equatable {
    case missingAsset(String)
    case unsafeRelativePath(String)
    case conflictingAssetDestination(String)

    public var description: String {
        switch self {
        case let .missingAsset(path):
            return "export asset is missing: \(path)"
        case let .unsafeRelativePath(path):
            return "export asset path escapes the bundle: \(path)"
        case let .conflictingAssetDestination(path):
            return "multiple assets target the same export path: \(path)"
        }
    }
}

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
///     <project-relative paths>        asset files and external model dependencies
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
                              sourceProjectDirectory: URL? = nil,
                              to outputDirectory: URL) throws -> ProjectExportDescriptor {
        let fileManager = FileManager.default
        let parentDirectory = outputDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let stagingDirectory = parentDirectory.appendingPathComponent(
            ".\(outputDirectory.lastPathComponent).staging-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: stagingDirectory) }
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        // Scene → GameSaveDocument at slot 0: the exact format GameApplication loads.
        let save = GameSaveDocument(slot: sceneSlot, manifest: manifest)
        try save.write(to: GameSaveDocument.url(slot: sceneSlot, projectDirectory: stagingDirectory.path))

        try copyAssets(assets, to: stagingDirectory, fileManager: fileManager)
        if let sourceProjectDirectory {
            try copyAudioResources(from: sourceProjectDirectory,
                                   to: stagingDirectory,
                                   fileManager: fileManager)
        }

        let assetList = ProjectExportAssetList(assets: assets.map {
            ProjectExportAsset(id: $0.id, name: $0.name, relativePath: $0.relativePath,
                               kind: $0.kind.rawValue, meshIndex: $0.meshIndex)
        })
        try writeJSON(assetList, to: stagingDirectory.appendingPathComponent("assets.json"))

        let descriptor = ProjectExportDescriptor(
            schemaVersion: schemaVersion,
            appName: appName,
            exportedAt: ISO8601DateFormatter().string(from: Date()),
            entityCount: manifest.entityCount,
            assetCount: assets.count,
            sceneSlot: sceneSlot
        )
        try writeJSON(descriptor, to: stagingDirectory.appendingPathComponent("build.json"))
        try replaceBundle(at: outputDirectory,
                          with: stagingDirectory,
                          fileManager: fileManager)
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

    private static func copyAssets(_ assets: [EditorAsset],
                                   to outputDirectory: URL,
                                   fileManager: FileManager) throws {
        var copiedDestinations: [String: String] = [:]
        for asset in assets {
            let source = URL(fileURLWithPath: asset.absolutePath)
            let destinationParent = (asset.relativePath as NSString).deletingLastPathComponent
            for file in AssetImportResolver.resolve(source) {
                guard fileManager.fileExists(atPath: file.source.path) else {
                    throw ProjectExporterError.missingAsset(file.source.path)
                }
                let relativePath = destinationParent == "."
                    ? file.relativePath
                    : destinationParent + "/" + file.relativePath
                let destination = try safeDestination(relativePath: relativePath,
                                                      in: outputDirectory)
                let sourcePath = file.source.resolvingSymlinksInPath().path
                if let existingSource = copiedDestinations[destination.path] {
                    guard existingSource == sourcePath else {
                        throw ProjectExporterError.conflictingAssetDestination(relativePath)
                    }
                    continue
                }
                copiedDestinations[destination.path] = sourcePath
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                try fileManager.copyItem(at: file.source, to: destination)
            }
        }
    }

    private static let audioExtensions: Set<String> = ["wav", "mp3", "m4a", "aiff", "aif", "caf", "ogg"]
    private static let excludedResourceDirectories: Set<String> = [
        ".git", ".guava", ".build", "build", "export", "node_modules", ".gradle",
    ]

    private static func copyAudioResources(from sourceDirectory: URL,
                                           to outputDirectory: URL,
                                           fileManager: FileManager) throws {
        let sourceRoot = sourceDirectory.resolvingSymlinksInPath()
        let properties: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(at: sourceRoot,
                                                      includingPropertiesForKeys: properties,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return
        }
        for case let source as URL in enumerator {
            let values = try source.resourceValues(forKeys: Set(properties))
            if values.isDirectory == true {
                if excludedResourceDirectories.contains(source.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true,
                  audioExtensions.contains(source.pathExtension.lowercased()) else { continue }
            let resolvedSourcePath = source.resolvingSymlinksInPath().path
            let sourceRootPrefix = sourceRoot.path.hasSuffix("/")
                ? sourceRoot.path
                : sourceRoot.path + "/"
            guard resolvedSourcePath.hasPrefix(sourceRootPrefix) else { continue }
            let relativePath = String(resolvedSourcePath.dropFirst(sourceRootPrefix.count))
            let destination = try safeDestination(relativePath: relativePath, in: outputDirectory)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            if !fileManager.fileExists(atPath: destination.path) {
                try fileManager.copyItem(at: source, to: destination)
            }
        }
    }

    private static func safeDestination(relativePath: String,
                                        in root: URL) throws -> URL {
        let standardizedRoot = root.standardizedFileURL
        let destination = standardizedRoot.appendingPathComponent(relativePath).standardizedFileURL
        let rootPrefix = standardizedRoot.path.hasSuffix("/")
            ? standardizedRoot.path
            : standardizedRoot.path + "/"
        guard destination.path.hasPrefix(rootPrefix) else {
            throw ProjectExporterError.unsafeRelativePath(relativePath)
        }
        return destination
    }

    private static func replaceBundle(at outputDirectory: URL,
                                      with stagingDirectory: URL,
                                      fileManager: FileManager) throws {
        let backupDirectory = outputDirectory.deletingLastPathComponent().appendingPathComponent(
            ".\(outputDirectory.lastPathComponent).backup-\(UUID().uuidString)",
            isDirectory: true
        )
        let hadExistingBundle = fileManager.fileExists(atPath: outputDirectory.path)
        if hadExistingBundle {
            try fileManager.moveItem(at: outputDirectory, to: backupDirectory)
        }
        do {
            try fileManager.moveItem(at: stagingDirectory, to: outputDirectory)
            if hadExistingBundle {
                try? fileManager.removeItem(at: backupDirectory)
            }
        } catch {
            if hadExistingBundle,
               !fileManager.fileExists(atPath: outputDirectory.path) {
                try? fileManager.moveItem(at: backupDirectory, to: outputDirectory)
            }
            throw error
        }
    }
}

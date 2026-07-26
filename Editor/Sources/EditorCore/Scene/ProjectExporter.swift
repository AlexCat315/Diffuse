import Foundation

public enum ProjectExporterError: Error, CustomStringConvertible, Equatable {
    case missingAsset(String)
    case missingPlayerExecutable(String)
    case unsafeRelativePath(String)
    case conflictingAssetDestination(String)
    case outputContainsSourceProject(String)

    public var description: String {
        switch self {
        case let .missingAsset(path):
            return "export asset is missing: \(path)"
        case let .missingPlayerExecutable(path):
            return "GuavaPlayer executable is missing or not executable: \(path)"
        case let .unsafeRelativePath(path):
            return "export asset path escapes the bundle: \(path)"
        case let .conflictingAssetDestination(path):
            return "multiple assets target the same export path: \(path)"
        case let .outputContainsSourceProject(path):
            return "export output cannot contain the source project: \(path)"
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
///     Scripts/scripts.json           optional project script aliases and defaults
///     .guava/game-saves/slot-0.json  scene captured as a GameSaveDocument
///     <project-relative paths>        asset files and external model dependencies
///
/// When a `playerExecutableURL` is supplied, the export also contains a macOS
/// application bundle with the project data embedded under Contents/Resources.
public enum ProjectExporter {
    public static let schemaVersion = 1
    public static let sceneSlot = 0

    @discardableResult
    public static func export(manifest: EditorSceneManifest,
                              appName: String,
                              assets: [EditorAsset] = [],
                              sourceProjectDirectory: URL? = nil,
                              playerExecutableURL: URL? = nil,
                              to outputDirectory: URL) throws -> ProjectExportDescriptor {
        let fileManager = FileManager.default
        if let sourceProjectDirectory {
            let sourcePath = sourceProjectDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            let outputPath = outputDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            guard !pathContains(sourcePath, root: outputPath) else {
                throw ProjectExporterError.outputContainsSourceProject(outputDirectory.path)
            }
        }
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
                                   excluding: [outputDirectory, stagingDirectory],
                                   fileManager: fileManager)
            try copyProjectScriptCatalog(from: sourceProjectDirectory,
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
        if let playerExecutableURL {
            try createApplicationBundle(appName: appName,
                                        playerExecutableURL: playerExecutableURL,
                                        projectDirectory: stagingDirectory,
                                        fileManager: fileManager)
        }
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

    public static func applicationBundleURL(appName: String,
                                            in outputDirectory: URL) -> URL {
        outputDirectory.appendingPathComponent("\(safeApplicationName(appName)).app",
                                               isDirectory: true)
    }

    public static func applicationExecutableURL(appName: String,
                                                in outputDirectory: URL) -> URL {
        applicationBundleURL(appName: appName, in: outputDirectory)
            .appendingPathComponent("Contents/MacOS/\(safeApplicationName(appName))")
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: [.atomic])
    }

    private static func createApplicationBundle(appName: String,
                                                playerExecutableURL: URL,
                                                projectDirectory: URL,
                                                fileManager: FileManager) throws {
        guard fileManager.isExecutableFile(atPath: playerExecutableURL.path) else {
            throw ProjectExporterError.missingPlayerExecutable(playerExecutableURL.path)
        }

        // Capture the portable project entries before creating the app inside
        // that same staging directory, avoiding recursive self-copy.
        let projectEntries = try fileManager.contentsOfDirectory(
            at: projectDirectory,
            includingPropertiesForKeys: nil,
            options: []
        )
        let safeName = safeApplicationName(appName)
        let appURL = applicationBundleURL(appName: appName, in: projectDirectory)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let bundledProjectURL = resourcesURL.appendingPathComponent("GuavaProject", isDirectory: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bundledProjectURL, withIntermediateDirectories: true)

        let executableURL = macOSURL.appendingPathComponent(safeName)
        try fileManager.copyItem(at: playerExecutableURL, to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: executableURL.path)

        // SwiftPM's generated Bundle.module accessor looks next to Bundle.main
        // (the .app root), so retain all sibling resource bundles there.
        let playerDirectory = playerExecutableURL.deletingLastPathComponent()
        let siblingResources = try fileManager.contentsOfDirectory(
            at: playerDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for resource in siblingResources where resource.pathExtension == "bundle" {
            try fileManager.copyItem(at: resource,
                                     to: appURL.appendingPathComponent(resource.lastPathComponent,
                                                                       isDirectory: true))
        }

        for entry in projectEntries {
            try fileManager.copyItem(at: entry,
                                     to: bundledProjectURL.appendingPathComponent(entry.lastPathComponent,
                                                                                  isDirectory: false))
        }

        let info: [String: Any] = [
            "CFBundleDisplayName": appName,
            "CFBundleExecutable": safeName,
            "CFBundleIdentifier": "com.guava.export.\(bundleIdentifierSuffix(safeName))",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": appName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0",
            "NSHighResolutionCapable": true,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info,
                                                       format: .xml,
                                                       options: 0)
        try plist.write(to: contentsURL.appendingPathComponent("Info.plist"), options: [.atomic])
    }

    private static func safeApplicationName(_ appName: String) -> String {
        let allowed = CharacterSet.alphanumerics
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_."))
        let sanitizedScalars = appName.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(String(scalar)) : "_"
        }
        let sanitized = String(sanitizedScalars)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Guava Game" : sanitized
    }

    private static func bundleIdentifierSuffix(_ value: String) -> String {
        let mapped = value.lowercased().unicodeScalars.map { scalar -> Character in
            let code = scalar.value
            let isASCIIAlphaNumeric = (48...57).contains(code) || (97...122).contains(code)
            return isASCIIAlphaNumeric ? Character(String(scalar)) : "-"
        }
        let components = String(mapped).split(separator: "-", omittingEmptySubsequences: true)
        return components.isEmpty ? "game" : components.joined(separator: "-")
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
                                           excluding excludedDirectories: [URL] = [],
                                           fileManager: FileManager) throws {
        let sourceRoot = sourceDirectory.resolvingSymlinksInPath()
        let excludedPaths = excludedDirectories.map {
            $0.resolvingSymlinksInPath().standardizedFileURL.path
        }
        let properties: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(at: sourceRoot,
                                                      includingPropertiesForKeys: properties,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return
        }
        for case let source as URL in enumerator {
            let values = try source.resourceValues(forKeys: Set(properties))
            if values.isDirectory == true {
                let resolvedPath = source.resolvingSymlinksInPath().standardizedFileURL.path
                if excludedResourceDirectories.contains(source.lastPathComponent)
                    || excludedPaths.contains(where: { pathContains(resolvedPath, root: $0) }) {
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

    private static func pathContains(_ candidate: String, root: String) -> Bool {
        guard candidate != root else { return true }
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        return candidate.hasPrefix(rootPrefix)
    }

    private static func copyProjectScriptCatalog(from sourceDirectory: URL,
                                                 to outputDirectory: URL,
                                                 fileManager: FileManager) throws {
        let source = sourceDirectory.appendingPathComponent(ProjectScriptCatalog.relativePath)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let destination = try safeDestination(relativePath: ProjectScriptCatalog.relativePath,
                                              in: outputDirectory)
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        try fileManager.copyItem(at: source, to: destination)
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

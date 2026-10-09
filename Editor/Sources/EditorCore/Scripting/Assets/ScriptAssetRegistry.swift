import Foundation

/// Project-stable identity for a Swift script asset.
///
/// File names are presentation. References, build products, and runtime
/// registrations use this identity so renaming `Player.swift` does not break
/// scene bindings or create a second runtime script.
public struct ScriptAssetID: Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var runtimeIdentifier: String {
        "scripts.asset.\(rawValue.uuidString.lowercased())"
    }

    public var shortDescription: String {
        String(rawValue.uuidString.lowercased().prefix(8))
    }

    public var description: String { runtimeIdentifier }
}

struct ResolvedScriptAsset: Sendable, Equatable {
    let id: ScriptAssetID
    let url: URL
    let legacyIdentifiers: [String]
}

/// Persistent identity map stored with the project at
/// `.guava/script-assets.json`.
///
/// A content fingerprint is only a rename-reconciliation hint. Identity never
/// derives from the fingerprint: ambiguous matches receive a new UUID instead
/// of risking that two equal files exchange identities.
final class ScriptAssetRegistry: @unchecked Sendable {
    private struct Record: Codable, Sendable, Equatable {
        var id: ScriptAssetID
        var relativePath: String
        var contentFingerprint: String
        var fileSystemIdentity: String?
        var legacyIdentifiers: [String]
    }

    private struct Document: Codable, Sendable {
        var version: Int
        var assets: [Record]
    }

    private let scriptsDirectoryURL: URL
    private let storageURL: URL
    private let lock = NSLock()
    private var records: [Record]?

    init(projectDirectory: String) {
        let projectURL = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        self.scriptsDirectoryURL = projectURL.appendingPathComponent("Scripts", isDirectory: true)
        self.storageURL = projectURL
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("script-assets.json")
    }

    func resolve(_ urls: [URL]) throws -> [ResolvedScriptAsset] {
        lock.lock()
        defer { lock.unlock() }

        var current = try loadIfNeeded()
        let relativePaths = Set(urls.map(relativePath(for:)))
        var claimedIDs = Set<ScriptAssetID>()
        var didChange = false
        var resolved: [ResolvedScriptAsset] = []

        for url in urls.sorted(by: { $0.lastPathComponent.localizedCaseInsensitiveCompare(
            $1.lastPathComponent
        ) == .orderedAscending }) {
            let path = relativePath(for: url)
            let fingerprint = try Self.fingerprint(of: url)
            let fileSystemIdentity = Self.fileSystemIdentity(of: url)
            let legacyIdentifier = DynamicScriptManager.legacyIdentifier(forFileStem:
                url.deletingPathExtension().lastPathComponent
            )

            var index = current.firstIndex { $0.relativePath == path }
            if index == nil {
                let identityCandidates = current.indices.filter { candidate in
                    !claimedIDs.contains(current[candidate].id)
                        && !relativePaths.contains(current[candidate].relativePath)
                        && fileSystemIdentity != nil
                        && current[candidate].fileSystemIdentity == fileSystemIdentity
                }
                if identityCandidates.count == 1 {
                    index = identityCandidates[0]
                } else {
                    let fingerprintCandidates = current.indices.filter { candidate in
                        !claimedIDs.contains(current[candidate].id)
                            && !relativePaths.contains(current[candidate].relativePath)
                            && current[candidate].contentFingerprint == fingerprint
                    }
                    if fingerprintCandidates.count == 1 {
                        index = fingerprintCandidates[0]
                    }
                }
            }

            if let index {
                claimedIDs.insert(current[index].id)
                if current[index].relativePath != path {
                    current[index].relativePath = path
                    didChange = true
                }
                if current[index].contentFingerprint != fingerprint {
                    current[index].contentFingerprint = fingerprint
                    didChange = true
                }
                if current[index].fileSystemIdentity != fileSystemIdentity {
                    current[index].fileSystemIdentity = fileSystemIdentity
                    didChange = true
                }
                if !current[index].legacyIdentifiers.contains(legacyIdentifier) {
                    current[index].legacyIdentifiers.append(legacyIdentifier)
                    current[index].legacyIdentifiers.sort()
                    didChange = true
                }
                resolved.append(ResolvedScriptAsset(id: current[index].id,
                                                    url: url,
                                                    legacyIdentifiers: current[index].legacyIdentifiers))
            } else {
                let record = Record(id: ScriptAssetID(),
                                    relativePath: path,
                                    contentFingerprint: fingerprint,
                                    fileSystemIdentity: fileSystemIdentity,
                                    legacyIdentifiers: [legacyIdentifier])
                current.append(record)
                claimedIDs.insert(record.id)
                resolved.append(ResolvedScriptAsset(id: record.id,
                                                    url: url,
                                                    legacyIdentifiers: record.legacyIdentifiers))
                didChange = true
            }
        }

        current.sort { $0.relativePath.localizedCaseInsensitiveCompare($1.relativePath) == .orderedAscending }
        records = current
        if didChange { try save(current) }
        return resolved
    }

    func remove(assetID: ScriptAssetID) throws {
        lock.lock()
        defer { lock.unlock() }
        var current = try loadIfNeeded()
        let previousCount = current.count
        current.removeAll { $0.id == assetID }
        guard current.count != previousCount else { return }
        records = current
        try save(current)
    }

    private func loadIfNeeded() throws -> [Record] {
        if let records { return records }
        guard FileManager.default.fileExists(atPath: storageURL.path) else {
            records = []
            return []
        }
        do {
            let document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: storageURL))
            guard document.version == 1 else {
                throw ScriptAssetRegistryError.unsupportedVersion(document.version)
            }
            records = document.assets
            return document.assets
        } catch let error as ScriptAssetRegistryError {
            throw error
        } catch {
            throw ScriptAssetRegistryError.invalidRegistry(error.localizedDescription)
        }
    }

    private func save(_ records: [Record]) throws {
        let directory = storageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, assets: records))
        try data.write(to: storageURL, options: .atomic)
    }

    private func relativePath(for url: URL) -> String {
        let base = scriptsDirectoryURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    private static func fingerprint(of url: URL) throws -> String {
        let bytes = try Data(contentsOf: url)
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in bytes {
            first = (first ^ UInt64(byte)) &* 0x100000001b3
            second = (second ^ UInt64(byte &+ 0x9d)) &* 0x100000001b3
        }
        return String(format: "%016llx%016llx", first, second)
    }

    private static func fileSystemIdentity(of url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let file = attributes[.systemFileNumber] as? NSNumber else { return nil }
        let system = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        return "\(system):\(file.uint64Value)"
    }
}

enum ScriptAssetRegistryError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case invalidRegistry(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported script asset registry version \(version)."
        case .invalidRegistry(let reason):
            return "The script asset registry is unreadable: \(reason)"
        }
    }
}

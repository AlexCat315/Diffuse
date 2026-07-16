import Foundation
import PluginRuntime

public enum EditorPluginAuthorizationStoreError: Error, Sendable, Equatable,
    LocalizedError {
    case duplicatePlugin(String)
    case couldNotEncode

    public var errorDescription: String? {
        switch self {
        case let .duplicatePlugin(id):
            return "Plugin authorization storage contains duplicate plugin '\(id)'."
        case .couldNotEncode:
            return "Plugin authorization storage could not be encoded."
        }
    }
}

/// Project-scoped record of explicit user decisions. Records are not an
/// enable-list: opening a project never loads a plugin from this file. The UI
/// may reuse a record only after `isStillValid(for:)` binds it to the current
/// inspection, and `EditorApplication.enablePlugin` still asks PluginHost to
/// validate the package again before exposure.
public final class EditorPluginAuthorizationStore: @unchecked Sendable {
    private struct Document: Codable {
        var formatVersion: Int
        var records: [PluginAuthorizationRecord]

        enum CodingKeys: String, CodingKey {
            case formatVersion = "format_version"
            case records
        }
    }

    public let storageURL: URL
    private let lock = NSLock()
    private var recordsByPluginID: [String: PluginAuthorizationRecord] = [:]

    public init(projectDirectory: String) {
        storageURL = URL(fileURLWithPath: projectDirectory, isDirectory: true)
            .appendingPathComponent(".guava", isDirectory: true)
            .appendingPathComponent("plugin_authorizations.json")
        recordsByPluginID = (try? Self.load(from: storageURL)) ?? [:]
    }

    public func authorization(for inspection: PluginInspection)
        -> PluginAuthorizationRecord? {
        lock.withLock {
            guard let record = recordsByPluginID[inspection.manifest.id],
                  record.isStillValid(for: inspection) else { return nil }
            return record
        }
    }

    public func record(_ authorization: PluginAuthorizationRecord) throws {
        try lock.withLock {
            var next = recordsByPluginID
            next[authorization.pluginID] = authorization
            try persist(next)
            recordsByPluginID = next
        }
    }

    public func remove(pluginID: String) throws {
        try lock.withLock {
            var next = recordsByPluginID
            next.removeValue(forKey: pluginID)
            try persist(next)
            recordsByPluginID = next
        }
    }

    public func allRecords() -> [PluginAuthorizationRecord] {
        lock.withLock {
            recordsByPluginID.values.sorted { $0.pluginID < $1.pluginID }
        }
    }

    private static func load(from url: URL) throws
        -> [String: PluginAuthorizationRecord] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        let document = try JSONDecoder().decode(Document.self,
                                                from: Data(contentsOf: url))
        guard document.formatVersion == 1 else { return [:] }
        var result: [String: PluginAuthorizationRecord] = [:]
        for record in document.records {
            guard result.updateValue(record, forKey: record.pluginID) == nil else {
                throw EditorPluginAuthorizationStoreError.duplicatePlugin(record.pluginID)
            }
        }
        return result
    }

    private func persist(_ records: [String: PluginAuthorizationRecord]) throws {
        let document = Document(formatVersion: 1,
                                records: records.values.sorted {
                                    $0.pluginID < $1.pluginID
                                })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(document) else {
            throw EditorPluginAuthorizationStoreError.couldNotEncode
        }
        try FileManager.default.createDirectory(
            at: storageURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: storageURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: storageURL.path
        )
    }
}

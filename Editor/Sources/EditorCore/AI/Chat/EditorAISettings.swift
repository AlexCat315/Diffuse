private import CoveFileSystem
import AIRuntime
import CapabilityRuntime
import Foundation

// MARK: - Settings

public struct EditorAISettings: Codable, Sendable, Equatable {
    /// The plugin-contributed provider id; empty disables the assistant.
    public var providerID: String
    public var model: String
    /// The contributed agent id; empty picks the first enabled agent.
    public var agentID: String
    /// Compatibility preference for read-only/legacy flows. Capability-backed
    /// AI writes always escalate to the required preview confirmation policy.
    public var autoApprove: Bool

    public var isEnabled: Bool { !providerID.isEmpty }

    public static let `default` = EditorAISettings()

    public init(providerID: String = "", model: String = "", agentID: String = "", autoApprove: Bool = false) {
        self.providerID = providerID
        self.model = model
        self.agentID = agentID
        self.autoApprove = autoApprove
    }

    private enum CodingKeys: String, CodingKey {
        case providerID = "provider_id"
        case agentID = "agent_id"
        case model, autoApprove
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        providerID = try c.decodeIfPresent(String.self, forKey: .providerID) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        agentID = try c.decodeIfPresent(String.self, forKey: .agentID) ?? ""
        autoApprove = try c.decodeIfPresent(Bool.self, forKey: .autoApprove) ?? false
    }
}

// MARK: - Capability Settings

public enum EditorCapabilityReleasePhase: String, Codable, Sendable, Equatable, CaseIterable {
    case stable
    case beta
    case experimental

    public var displayName: String {
        switch self {
        case .stable:       return "Stable"
        case .beta:         return "Beta"
        case .experimental: return "Experimental"
        }
    }

    var runtimePhase: CapabilityReleasePhase {
        switch self {
        case .stable:       return .stable
        case .beta:         return .beta
        case .experimental: return .experimental
        }
    }
}

public struct EditorCapabilitySettings: Codable, Sendable, Equatable {
    public var releasePhase: EditorCapabilityReleasePhase

    public static let `default` = EditorCapabilitySettings(releasePhase: .stable)

    public init(releasePhase: EditorCapabilityReleasePhase = .stable) {
        self.releasePhase = releasePhase
    }

    private enum CodingKeys: String, CodingKey {
        case releasePhase
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        releasePhase = try values.decodeIfPresent(EditorCapabilityReleasePhase.self,
                                                  forKey: .releasePhase) ?? .stable
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(releasePhase, forKey: .releasePhase)
    }
}

// MARK: - Key store

public enum AICredentialStoreError: Error, Sendable, Equatable, LocalizedError {
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .writeFailed(reason): "The credential could not be saved: \(reason)"
        }
    }
}

public enum AICredentialSource: Sendable, Equatable {
    case credentialFile
    case environment(variable: String)
}

/// Provider credentials in one file only the user can read
/// (`~/Library/Application Support/Diffuse/Credentials/ai-providers.json`,
/// mode 0600 inside a 0700 folder), one value per auth field the provider
/// declares. Values are never written to project files, settings JSON,
/// prompts, logs, or plugins; a field's environment variable fills in a value
/// the file does not hold.
public enum AICredentialStore {
    /// Provider ID → auth field ID → value.
    typealias Values = [String: [String: String]]

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return base.appendingPathComponent("Diffuse/Credentials/ai-providers.json")
    }

    /// Stores the given fields' values; an empty value removes that field.
    public static func save(_ values: [String: String], providerID: String) throws {
        try save(values, providerID: providerID, at: fileURL)
    }

    static func save(_ values: [String: String], providerID: String, at url: URL) throws {
        var stored = stored(at: url)
        var fields = stored[providerID] ?? [:]
        for (field, value) in values { fields[field] = value.isEmpty ? nil : value }
        stored[providerID] = fields.isEmpty ? nil : fields
        do {
            let directory = url.deletingLastPathComponent()
            try FilePermissions.createPrivateDirectory(at: directory)
            try AtomicFile.write(JSONEncoder().encode(stored), to: url, access: .ownerOnly)

        } catch {
            throw AICredentialStoreError.writeFailed(error.localizedDescription)
        }
    }

    public static func load(_ field: AIAuthFieldDescriptor, providerID: String) -> String? {
        stored(at: fileURL)[providerID]?[field.id]
            ?? environmentCredential(variable: field.environmentVariable,
                                     environment: ProcessInfo.processInfo.environment)?.key
    }

    public static func credentialSource(for field: AIAuthFieldDescriptor,
                                        providerID: String) -> AICredentialSource? {
        if stored(at: fileURL)[providerID]?[field.id] != nil { return .credentialFile }
        return environmentCredential(variable: field.environmentVariable,
                                     environment: ProcessInfo.processInfo.environment)
            .map { .environment(variable: $0.variable) }
    }

    /// Removes every stored field of the provider.
    public static func delete(providerID: String) throws {
        let fields = stored(at: fileURL)[providerID] ?? [:]
        try save(fields.mapValues { _ in "" }, providerID: providerID)
    }

    static func stored(at url: URL) -> Values {
        guard let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode(Values.self, from: data) else { return [:] }
        return values.mapValues { $0.filter { !$0.value.isEmpty } }.filter { !$0.value.isEmpty }
    }

    static func environmentCredential(
        variable: String?,
        environment: [String: String]
    ) -> (variable: String, key: String)? {
        guard let variable else { return nil }
        guard let value = environment[variable]?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !value.isEmpty else { return nil }
        return (variable, value)
    }
}

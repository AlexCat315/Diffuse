import Foundation

/// How invoking a capability may affect state. The host, not a plugin or model,
/// decides the effective access level.
public enum CapabilityAccess: String, Codable, Sendable, Equatable, CaseIterable {
    case read
    case reversibleWrite = "reversible_write"
    case destructiveWrite = "destructive_write"
    case externalSideEffect = "external_side_effect"

    public var isWrite: Bool {
        switch self {
        case .read: return false
        case .reversibleWrite, .destructiveWrite, .externalSideEffect: return true
        }
    }
}

public enum CapabilitySourceKind: String, Codable, Sendable, Equatable {
    case builtin
    case plugin
}

public struct CapabilitySource: Codable, Sendable, Equatable {
    public var kind: CapabilitySourceKind
    public var pluginID: String?

    public init(kind: CapabilitySourceKind, pluginID: String? = nil) {
        self.kind = kind
        self.pluginID = pluginID
    }

    public static let builtin = CapabilitySource(kind: .builtin)

    public static func plugin(_ id: String) -> CapabilitySource {
        CapabilitySource(kind: .plugin, pluginID: id)
    }
}

/// Exact plugin authority captured when a model-facing allow-list is created.
/// A schema hash alone cannot detect a component binary replacement or a
/// PluginHost restart, so plugin tools and Drafts also carry this binding.
public struct PluginCapabilityAuthority: Codable, Sendable, Equatable {
    public var pluginID: String
    public var authorizationDigest: String
    public var hostGeneration: UInt64

    public init(pluginID: String,
                authorizationDigest: String,
                hostGeneration: UInt64) {
        self.pluginID = pluginID
        self.authorizationDigest = authorizationDigest
        self.hostGeneration = hostGeneration
    }
}

/// Provider-neutral, serialisable contract for one AI-visible capability.
/// Provider and MCP tool definitions must be derived from this value.
public struct CapabilityContract: Codable, Sendable, Equatable {
    public var id: String
    public var version: Int
    public var title: String
    public var description: String
    public var domain: String
    public var access: CapabilityAccess
    public var releasePhase: CapabilityReleasePhase
    public var inputSchema: JSONSchema
    public var source: CapabilitySource
    public var schemaHash: String

    public init(id: String,
                version: Int = 1,
                title: String,
                description: String,
                domain: String,
                access: CapabilityAccess,
                releasePhase: CapabilityReleasePhase,
                inputSchema: JSONSchema,
                source: CapabilitySource = .builtin,
                schemaHash: String? = nil) {
        self.id = id
        self.version = version
        self.title = Self.sanitiseMetadata(title, maximumLength: 80)
        self.description = Self.sanitiseMetadata(description, maximumLength: 1_024)
        self.domain = domain
        self.access = access
        self.releasePhase = releasePhase
        self.inputSchema = inputSchema
        self.source = source
        self.schemaHash = schemaHash ?? ""
        if schemaHash == nil {
            self.schemaHash = Self.fingerprint(id: id,
                                               version: version,
                                               title: self.title,
                                               description: self.description,
                                               domain: domain,
                                               access: access,
                                               releasePhase: releasePhase,
                                               inputSchema: inputSchema,
                                               source: source)
        }
    }

    /// A collision-resistant provider tool name. The suffix binds it to this
    /// exact contract, while the readable prefix helps diagnostics.
    public var toolName: String {
        let readable = id.lowercased().map { character -> Character in
            if character.isLetter || character.isNumber { return character }
            return "_"
        }
        let collapsed = String(readable).replacingOccurrences(of: "__", with: "_")
        let prefix = String(collapsed.prefix(44)).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        return "cap_\(prefix)_v\(version)_\(schemaHash.prefix(8))"
    }

    public func anthropicToolDefinition() -> [String: Any] {
        [
            "name": toolName,
            "description": description,
            "input_schema": inputSchema.jsonObject(),
        ]
    }

    public func openAIToolDefinition() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": toolName,
                "description": description,
                "parameters": inputSchema.jsonObject(),
            ] as [String: Any],
        ]
    }

    public func openAIResponsesToolDefinition(name: String? = nil) -> [String: Any] {
        [
            "type": "function",
            "name": name ?? toolName,
            "description": description,
            "parameters": inputSchema.jsonObject(),
        ]
    }

    public func mcpToolDefinition() -> [String: Any] {
        [
            "name": toolName,
            "description": description,
            "inputSchema": inputSchema.jsonObject(),
        ]
    }

    /// Digest of the already validated canonical capability input. This is an
    /// audit identifier, not a secret-bearing value.
    public func inputDigest(_ data: Data) -> String {
        CapabilitySHA256.hexDigest(data)
    }

    private static func fingerprint(id: String,
                                    version: Int,
                                    title: String,
                                    description: String,
                                    domain: String,
                                    access: CapabilityAccess,
                                    releasePhase: CapabilityReleasePhase,
                                    inputSchema: JSONSchema,
                                    source: CapabilitySource) -> String {
        var sourceObject: [String: Any] = ["kind": source.kind.rawValue]
        if let pluginID = source.pluginID { sourceObject["plugin_id"] = pluginID }
        let object: [String: Any] = [
            "id": id,
            "version": version,
            "title": title,
            "description": description,
            "domain": domain,
            "access": access.rawValue,
            "release_phase": releasePhase.rawValue,
            "input_schema": inputSchema.jsonObject(),
            "source": sourceObject,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return CapabilitySHA256.hexDigest(data)
    }

    /// Tool descriptions supplied by plugins are untrusted prompt content.
    /// Keep them plain, bounded, and free of control characters.
    public static func sanitiseMetadata(_ value: String, maximumLength: Int) -> String {
        let scalars = value.unicodeScalars.filter { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                return false
            default:
                return !CharacterSet.controlCharacters.contains(scalar)
            }
        }
        return String(String.UnicodeScalarView(scalars).prefix(maximumLength))
    }
}

public struct CapabilityExposurePolicy: Sendable, Equatable {
    public var activeReleasePhase: CapabilityReleasePhase
    public var allowedDomains: Set<String>?
    public var enabledPluginIDs: Set<String>
    public var allowExternalSideEffects: Bool
    public var maximumCapabilities: Int

    public init(activeReleasePhase: CapabilityReleasePhase = .stable,
                allowedDomains: Set<String>? = nil,
                enabledPluginIDs: Set<String> = [],
                allowExternalSideEffects: Bool = false,
                maximumCapabilities: Int = 16) {
        self.activeReleasePhase = activeReleasePhase
        self.allowedDomains = allowedDomains
        self.enabledPluginIDs = enabledPluginIDs
        self.allowExternalSideEffects = allowExternalSideEffects
        self.maximumCapabilities = max(1, maximumCapabilities)
    }
}

/// Immutable allow-list captured for one inference turn. Tool names are only
/// valid within this snapshot and resolve to exact id/version/hash tuples.
public struct CapabilityExposureSnapshot: Codable, Sendable, Equatable {
    public var id: UUID
    public var generation: UInt64
    public var sceneRevision: UInt64?
    public var contracts: [CapabilityContract]
    public var createdAt: Date
    /// Optional for backward-compatible decoding of snapshots produced before
    /// plugin authority binding was introduced. Plugin contracts are never
    /// exposed without a matching entry.
    public var pluginAuthorities: [String: PluginCapabilityAuthority]?

    public init(id: UUID = UUID(),
                generation: UInt64,
                sceneRevision: UInt64?,
                contracts: [CapabilityContract],
                createdAt: Date = Date(),
                pluginAuthorities: [String: PluginCapabilityAuthority] = [:]) {
        self.id = id
        self.generation = generation
        self.sceneRevision = sceneRevision
        self.contracts = contracts.sorted { $0.id < $1.id }
        self.createdAt = createdAt
        self.pluginAuthorities = pluginAuthorities.isEmpty ? nil : pluginAuthorities
    }

    public func contract(forToolName name: String) -> CapabilityContract? {
        contracts.first { $0.toolName == name }
    }

    public func contract(id: String) -> CapabilityContract? {
        contracts.first { $0.id == id }
    }

    public func authority(forPluginID pluginID: String) -> PluginCapabilityAuthority? {
        pluginAuthorities?[pluginID]
    }
}

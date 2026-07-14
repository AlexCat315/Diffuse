import CapabilityRuntime
import Foundation

public enum PluginImportPermission: String, Codable, Sendable, CaseIterable, Hashable {
    case sceneQuery = "guava:scene/query"
    case selectionQuery = "guava:selection/query"
    case assetMetadataQuery = "guava:asset/metadata-query"
}

public struct PluginResourceLimits: Codable, Sendable, Equatable {
    public var maximumMemoryBytes: UInt64
    public var discoveryTimeoutMilliseconds: UInt64
    public var preparationTimeoutMilliseconds: UInt64
    public var maximumOutputBytes: Int
    public var maximumCapabilities: Int
    public var fuelPerInvocation: UInt64

    public init(maximumMemoryBytes: UInt64 = 64 * 1_024 * 1_024,
                discoveryTimeoutMilliseconds: UInt64 = 2_000,
                preparationTimeoutMilliseconds: UInt64 = 5_000,
                maximumOutputBytes: Int = 1_024 * 1_024,
                maximumCapabilities: Int = 64,
                fuelPerInvocation: UInt64 = 20_000_000) {
        self.maximumMemoryBytes = min(maximumMemoryBytes, 64 * 1_024 * 1_024)
        self.discoveryTimeoutMilliseconds = min(discoveryTimeoutMilliseconds, 2_000)
        self.preparationTimeoutMilliseconds = min(preparationTimeoutMilliseconds, 5_000)
        self.maximumOutputBytes = min(maximumOutputBytes, 1_024 * 1_024)
        self.maximumCapabilities = min(maximumCapabilities, 64)
        self.fuelPerInvocation = min(fuelPerInvocation, 20_000_000)
    }

    public static let secureDefault = PluginResourceLimits()
}

/// `plugin.json` contains package identity and authority only. Capability input
/// types are deliberately absent: `capabilities.wit` owns that contract.
public struct GuavaPluginManifest: Codable, Sendable, Equatable {
    public var id: String
    public var version: Int
    public var name: String
    public var description: String
    public var access: CapabilityAccess
    public var imports: [PluginImportPermission]
    public var composableHostCapabilities: [String]

    public init(id: String,
                version: Int,
                name: String,
                description: String,
                access: CapabilityAccess,
                imports: [PluginImportPermission] = [],
                composableHostCapabilities: [String] = []) {
        self.id = id
        self.version = version
        self.name = CapabilityContract.sanitiseMetadata(name, maximumLength: 80)
        self.description = CapabilityContract.sanitiseMetadata(description, maximumLength: 1_024)
        self.access = access
        self.imports = Array(Set(imports.map(\.rawValue))).compactMap(PluginImportPermission.init(rawValue:)).sorted {
            $0.rawValue < $1.rawValue
        }
        self.composableHostCapabilities = Array(Set(composableHostCapabilities)).sorted()
    }

    enum CodingKeys: String, CodingKey {
        case id, version, name, description, access, imports
        case composableHostCapabilities = "composable_host_capabilities"
    }
}

public enum PluginManifestValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidIdentifier
    case invalidVersion
    case emptyName
    case forbiddenMetadataField(String)
    case externalSideEffectsDisabled
    case unknownHostCapability(String)
    case pluginCapabilityCannotBeComposed(String)
    case accessUnderstatement(capabilityID: String)

    public var description: String {
        switch self {
        case .invalidIdentifier: return "plugin id must match [a-z][a-z0-9.-]{2,63}"
        case .invalidVersion: return "plugin version must be positive"
        case .emptyName: return "plugin name must not be empty"
        case let .forbiddenMetadataField(field): return "plugin.json must not define '\(field)'"
        case .externalSideEffectsDisabled: return "external side-effect plugins are disabled"
        case let .unknownHostCapability(id): return "unknown composed host capability '\(id)'"
        case let .pluginCapabilityCannotBeComposed(id): return "plugin capability '\(id)' cannot be used as a host primitive"
        case let .accessUnderstatement(id): return "plugin access understates composed capability '\(id)'"
        }
    }
}

public enum PluginManifestValidator {
    private static let forbiddenFields: Set<String> = [
        "schema", "inputSchema", "input_schema", "tools", "mutations",
        "transactionOperations", "sceneMutations",
    ]
    private static let allowedFields: Set<String> = [
        "id", "version", "name", "description", "access", "imports",
        "composable_host_capabilities",
    ]

    public static func decodeAndValidate(_ data: Data,
                                         registry: CapabilityRegistry = .default) throws -> GuavaPluginManifest {
        let raw = try JSONSerialization.jsonObject(with: data)
        guard let object = raw as? [String: Any] else {
            throw PluginManifestValidationError.invalidIdentifier
        }
        if let forbidden = forbiddenFields.first(where: { object[$0] != nil }) {
            throw PluginManifestValidationError.forbiddenMetadataField(forbidden)
        }
        if let unknown = object.keys.first(where: { !allowedFields.contains($0) }) {
            throw PluginManifestValidationError.forbiddenMetadataField(unknown)
        }
        let decoded = try JSONDecoder().decode(GuavaPluginManifest.self, from: data)
        let manifest = GuavaPluginManifest(id: decoded.id,
                                           version: decoded.version,
                                           name: decoded.name,
                                           description: decoded.description,
                                           access: decoded.access,
                                           imports: decoded.imports,
                                           composableHostCapabilities: decoded.composableHostCapabilities)
        try validate(manifest, registry: registry)
        return manifest
    }

    public static func validate(_ manifest: GuavaPluginManifest,
                                registry: CapabilityRegistry = .default) throws {
        let pattern = "^[a-z][a-z0-9.-]{2,63}$"
        guard manifest.id.range(of: pattern, options: .regularExpression) != nil else {
            throw PluginManifestValidationError.invalidIdentifier
        }
        guard manifest.version > 0 else { throw PluginManifestValidationError.invalidVersion }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginManifestValidationError.emptyName
        }
        guard manifest.access != .externalSideEffect else {
            throw PluginManifestValidationError.externalSideEffectsDisabled
        }
        for capabilityID in manifest.composableHostCapabilities {
            guard let descriptor = registry.descriptor(for: capabilityID) else {
                throw PluginManifestValidationError.unknownHostCapability(capabilityID)
            }
            guard descriptor.source.kind == .builtin else {
                throw PluginManifestValidationError.pluginCapabilityCannotBeComposed(capabilityID)
            }
            if riskRank(descriptor.access) > riskRank(manifest.access) {
                throw PluginManifestValidationError.accessUnderstatement(capabilityID: capabilityID)
            }
        }
    }

    private static func riskRank(_ access: CapabilityAccess) -> Int {
        switch access {
        case .read: return 0
        case .reversibleWrite: return 1
        case .destructiveWrite: return 2
        case .externalSideEffect: return 3
        }
    }
}

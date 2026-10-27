import CapabilityRuntime
import Foundation

public enum PluginImportPermission: String, Codable, Sendable, CaseIterable, Hashable {
    case sceneQuery = "cove:scene/query"
    case selectionQuery = "cove:selection/query"
    case assetMetadataQuery = "cove:asset/metadata-query"
    case process = "cove:process/host"
    case http = "cove:http/host"
    case editor = "diffuse:editor/host"
    case service = "cove:service/host"

    public var isSnapshot: Bool { [.sceneQuery, .selectionQuery, .assetMetadataQuery].contains(self) }

}

public struct PluginResourceLimits: Codable, Sendable, Equatable {
    public var discoveryTimeoutMilliseconds: UInt64
    public var preparationTimeoutMilliseconds: UInt64
    public var maximumOutputBytes: Int
    public var maximumCapabilities: Int

    public init(discoveryTimeoutMilliseconds: UInt64 = 2_000,
                preparationTimeoutMilliseconds: UInt64 = 5_000,
                maximumOutputBytes: Int = 1_024 * 1_024,
                maximumCapabilities: Int = 64) {
        self.discoveryTimeoutMilliseconds = min(discoveryTimeoutMilliseconds, 2_000)
        self.preparationTimeoutMilliseconds = min(preparationTimeoutMilliseconds, 5_000)
        self.maximumOutputBytes = min(maximumOutputBytes, 1_024 * 1_024)
        self.maximumCapabilities = min(maximumCapabilities, 64)
    }

    public static let secureDefault = PluginResourceLimits()

    /// For `host.processes[].entryPoints`: the editor calls them with whole tool
    /// output, the model never does. Size and fuel bounds are lifted to what
    /// the runtime can hold; the preparation deadline still bounds each call.
    public static let hostEntryPoint: PluginResourceLimits = {
        var limits = PluginResourceLimits()
        limits.maximumOutputBytes = 256 * 1_024 * 1_024
        return limits
    }()
}

/// `plugin.json` contains package identity and authority only. Capability input
/// types are deliberately absent: `capabilities.wit` owns that contract.
public struct CovePluginManifest: Codable, Sendable, Equatable {
    public var id: String
    public var version: Int
    public var name: String
    public var description: String
    public var access: CapabilityAccess
    public var imports: [PluginImportPermission]
    public var composableHostCapabilities: [String]
    /// Declared dependencies, `[]` when the manifest omits them. Sorted by
    /// kind then id so the value is deterministic for digests and comparisons.
    public var requires: [PluginRequirement]
    public var host: PluginHostPermissions
    public var contributes: ContributionDescriptor
    public var resources: [PluginResource] = []
    public var runtime: PluginRuntimeDeclaration?
    public var activation: [String] = []

    public init(id: String,
                version: Int,
                name: String,
                description: String,
                access: CapabilityAccess,
                imports: [PluginImportPermission] = [],
                composableHostCapabilities: [String] = [],
                requires: [PluginRequirement] = [],
                host: PluginHostPermissions = .init(),
                contributes: ContributionDescriptor = .init()) {
        self.id = id
        self.version = version
        self.name = CapabilityContract.sanitiseMetadata(name, maximumLength: 80)
        self.description = CapabilityContract.sanitiseMetadata(description, maximumLength: 1_024)
        self.access = access
        self.host = host
        self.contributes = contributes
        self.imports = Array(Set(imports.map(\.rawValue))).compactMap(PluginImportPermission.init(rawValue:)).sorted {
            $0.rawValue < $1.rawValue
        }
        self.composableHostCapabilities = Array(Set(composableHostCapabilities)).sorted()
        self.requires = requires.sorted {
            ($0.kind.rawValue, $0.id) < ($1.kind.rawValue, $1.id)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(String.self, forKey: .id),
                  version: try container.decode(Int.self, forKey: .version),
                  name: try container.decode(String.self, forKey: .name),
                  description: try container.decode(String.self, forKey: .description),
                  access: try container.decode(CapabilityAccess.self, forKey: .access),
                  imports: try container.decode([PluginImportPermission].self, forKey: .imports),
                  composableHostCapabilities: try container.decode([String].self,
                                                                    forKey: .composableHostCapabilities),
                  requires: try container.decodeIfPresent([PluginRequirement].self,
                                                          forKey: .requires) ?? [],
                  host: try container.decodeIfPresent(PluginHostPermissions.self, forKey: .host) ?? .init(),
                  contributes: try container.decodeIfPresent(ContributionDescriptor.self, forKey: .contributes) ?? .init())
        resources = try container.decodeIfPresent([PluginResource].self, forKey: .resources) ?? []
        runtime = try container.decodeIfPresent(PluginRuntimeDeclaration.self, forKey: .runtime)
        activation = try container.decodeIfPresent([String].self, forKey: .activation) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id, version, name, description, access, imports
        case composableHostCapabilities = "composable_host_capabilities"
        case requires, host, contributes, resources, runtime, activation
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
    case unsafeHostPrimitive(String)
    case invalidRequirement(String)
    case duplicateRequirement(String)
    case requirementOnSelf(String)
    case invalidHostPermissions
    case invalidContribution(String)

    public var description: String {
        switch self {
        case .invalidHostPermissions: return "invalid plugin process permissions"
        case let .invalidContribution(point): return "invalid plugin contribution '\(point)'"
        case .invalidIdentifier: return "plugin id must match [a-z][a-z0-9.-]{2,63}"
        case .invalidVersion: return "plugin version must be positive"
        case .emptyName: return "plugin name must not be empty"
        case let .forbiddenMetadataField(field): return "plugin.json must not define '\(field)'"
        case .externalSideEffectsDisabled: return "external side-effect plugins are disabled"
        case let .unknownHostCapability(id): return "unknown composed host capability '\(id)'"
        case let .pluginCapabilityCannotBeComposed(id): return "plugin capability '\(id)' cannot be used as a host primitive"
        case let .accessUnderstatement(id): return "plugin access understates composed capability '\(id)'"
        case let .unsafeHostPrimitive(id):
            return "host capability '\(id)' is not an AI-exposed strict write primitive"
        case let .invalidRequirement(id):
            return "plugin requirement '\(id)' is invalid"
        case let .duplicateRequirement(id):
            return "plugin requirement '\(id)' is declared more than once"
        case let .requirementOnSelf(id):
            return "plugin requirement '\(id)' points at the plugin itself"
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
        "composable_host_capabilities", "requires", "host", "contributes", "resources", "runtime", "activation",
    ]

    public static func decodeAndValidate(_ data: Data,
                                         registry: CapabilityRegistry = .default,
                                         contributions: ContributionPointRegistry = .standard) throws -> CovePluginManifest {
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
        let decoded = try JSONDecoder().decode(CovePluginManifest.self, from: data)
        try validate(decoded, registry: registry, contributions: contributions)
        return decoded
    }

    public static func validate(_ manifest: CovePluginManifest,
                                registry: CapabilityRegistry = .default,
                                contributions: ContributionPointRegistry = .standard) throws {
        try manifest.host.validate(imports: manifest.imports)
        try manifest.contributes.validate(in: contributions, host: manifest.host)
        guard Set(manifest.resources.map(\.id)).count == manifest.resources.count,
              Set(manifest.resources.map(\.path)).count == manifest.resources.count,
              manifest.resources.count <= 128,
              manifest.resources.allSatisfy({ !$0.id.isEmpty && !$0.kind.isEmpty && PluginResource.isValidPath($0.path) }),
              manifest.runtime.map({ $0.engine == "bun" && $0.entry == "plugin.js" && $0.compatibility == 1 }) ?? true,
              Set(manifest.activation).count == manifest.activation.count,
              manifest.activation.allSatisfy(PluginActivationEvent.isValid) else {
            throw PluginManifestValidationError.invalidContribution("package")
        }
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
            guard descriptor.isAIExposed,
                  descriptor.access.isWrite,
                  descriptor.inputSchema.isStrictCapabilityInput else {
                throw PluginManifestValidationError.unsafeHostPrimitive(capabilityID)
            }
        }
        var seenRequirements: Set<String> = []
        for requirement in manifest.requires {
            try validateRequirement(requirement, manifestID: manifest.id)
            let key = "\(requirement.kind.rawValue):\(requirement.id)"
            guard seenRequirements.insert(key).inserted else {
                throw PluginManifestValidationError.duplicateRequirement(requirement.id)
            }
        }
    }

    private static func validateRequirement(_ requirement: PluginRequirement,
                                            manifestID: String) throws {
        guard !requirement.id.isEmpty,
              requirement.id.count <= 128,
              requirement.id.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              requirement.minimumVersion.map({ $0 > 0 }) ?? true else {
            throw PluginManifestValidationError.invalidRequirement(requirement.id)
        }
        switch requirement.kind {
        case .plugin:
            guard requirement.id.range(of: "^[a-z][a-z0-9.-]{2,63}$",
                                       options: .regularExpression) != nil else {
                throw PluginManifestValidationError.invalidRequirement(requirement.id)
            }
            guard requirement.id != manifestID else {
                throw PluginManifestValidationError.requirementOnSelf(requirement.id)
            }
        case .capability:
            guard requirement.id.range(of: "^[a-z][a-z0-9._-]{0,127}$",
                                       options: .regularExpression) != nil else {
                throw PluginManifestValidationError.invalidRequirement(requirement.id)
            }
            // A package's own capabilities are `pluginID.capabilityName`; they
            // only exist once this package is mounted, so a self-requirement
            // could never be satisfied and is a manifest bug.
            let prefix = manifestID + "."
            let isOwnCapability = requirement.id.hasPrefix(prefix)
                && !requirement.id.dropFirst(prefix.count).contains(".")
            guard !isOwnCapability else {
                throw PluginManifestValidationError.requirementOnSelf(requirement.id)
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

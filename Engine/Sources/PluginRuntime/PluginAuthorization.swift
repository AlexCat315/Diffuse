import CapabilityRuntime
import Foundation

public struct PluginCapabilityDiscovery: Codable, Sendable, Equatable {
    public var capabilityIDs: [String]

    public init(capabilityIDs: [String]) {
        self.capabilityIDs = capabilityIDs.sorted()
    }

    enum CodingKeys: String, CodingKey {
        case capabilityIDs = "capability_ids"
    }
}

public enum PluginCapabilityValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case unknownCapability(String)

    public var description: String {
        switch self {
        case let .unknownCapability(id):
            return "plugin capability '\(id)' is absent from its validated WIT contract"
        }
    }
}

/// Builds the complete model-facing contract from package identity/authority
/// and WIT-derived input types. Runtime Component output is never consulted.
public enum PluginWITContractDeriver {
    public static func contracts(for package: ValidatedPluginPackage) -> [CapabilityContract] {
        package.witContract.capabilityInputs.map { input in
            CapabilityContract(
                id: package.manifest.id + "." + input.name,
                version: package.manifest.version,
                title: input.title,
                description: input.description.isEmpty
                    ? package.manifest.description
                    : input.description,
                domain: "plugin",
                access: package.manifest.access,
                releasePhase: .stable,
                inputSchema: input.inputSchema,
                source: .plugin(package.manifest.id)
            )
        }.sorted { $0.id < $1.id }
    }
}

/// Immutable result shown to the user before enabling a plugin. It binds the
/// exact code, WIT boundary, manifest authority, and AI-visible contracts.
public struct PluginInspection: Codable, Sendable, Equatable {
    public var manifest: GuavaPluginManifest
    public var componentHash: String
    public var witHash: String
    public var contracts: [CapabilityContract]

    public init(package: ValidatedPluginPackage,
                contracts: [CapabilityContract]) {
        manifest = package.manifest
        componentHash = package.componentHash
        witHash = package.witHash
        self.contracts = contracts.sorted { $0.id < $1.id }
    }

    public init(manifest: GuavaPluginManifest,
                componentHash: String,
                witHash: String,
                contracts: [CapabilityContract]) {
        self.manifest = manifest
        self.componentHash = componentHash
        self.witHash = witHash
        self.contracts = contracts.sorted { $0.id < $1.id }
    }
}

public enum PluginAuthorizationError: Error, Sendable, Equatable, CustomStringConvertible {
    case missing
    case noLongerValid
    case duplicateCapability(String)

    public var description: String {
        switch self {
        case .missing: return "plugin must be explicitly authorised before loading"
        case .noLongerValid: return "plugin code, WIT, permissions, or capability schemas changed; reauthorisation is required"
        case let .duplicateCapability(id): return "plugin authorisation contains duplicate capability '\(id)'"
        }
    }
}

public struct PluginAuthorizationRecord: Codable, Sendable, Equatable {
    public var pluginID: String
    public var pluginVersion: Int
    public var componentHash: String
    public var witHash: String
    public var imports: [PluginImportPermission]
    public var access: CapabilityAccess
    public var composableHostCapabilities: [String]
    public var capabilitySchemaHashes: [String: String]
    public var authorisedAt: Date

    public init(inspection: PluginInspection,
                authorisedAt: Date = Date()) throws {
        let hashes = try Self.schemaHashes(inspection.contracts)
        pluginID = inspection.manifest.id
        pluginVersion = inspection.manifest.version
        componentHash = inspection.componentHash
        witHash = inspection.witHash
        imports = inspection.manifest.imports
        access = inspection.manifest.access
        composableHostCapabilities = inspection.manifest.composableHostCapabilities
        capabilitySchemaHashes = hashes
        self.authorisedAt = authorisedAt
    }

    public init(package: ValidatedPluginPackage,
                contracts: [CapabilityContract],
                authorisedAt: Date = Date()) throws {
        try self.init(inspection: PluginInspection(package: package,
                                                   contracts: contracts),
                      authorisedAt: authorisedAt)
    }

    public func isStillValid(for inspection: PluginInspection) -> Bool {
        guard let hashes = try? Self.schemaHashes(inspection.contracts) else { return false }
        return pluginID == inspection.manifest.id
            && pluginVersion == inspection.manifest.version
            && componentHash == inspection.componentHash
            && witHash == inspection.witHash
            && imports == inspection.manifest.imports
            && access == inspection.manifest.access
            && composableHostCapabilities == inspection.manifest.composableHostCapabilities
            && capabilitySchemaHashes == hashes
    }

    public func isStillValid(for package: ValidatedPluginPackage,
                             contracts: [CapabilityContract]) -> Bool {
        isStillValid(for: PluginInspection(package: package, contracts: contracts))
    }

    /// Stable executable-authority fingerprint. `authorisedAt` is deliberately
    /// excluded: the authority is the exact code/WIT/permissions/schema tuple,
    /// not when a UI happened to persist the user's decision.
    public var authorityDigest: String {
        let object: [String: Any] = [
            "plugin_id": pluginID,
            "plugin_version": pluginVersion,
            "component_hash": componentHash,
            "wit_hash": witHash,
            "imports": imports.map(\.rawValue).sorted(),
            "access": access.rawValue,
            "composable_host_capabilities": composableHostCapabilities.sorted(),
            "capability_schema_hashes": capabilitySchemaHashes,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys])) ?? Data()
        return CapabilityDigest.sha256(data)
    }

    private static func schemaHashes(_ contracts: [CapabilityContract]) throws -> [String: String] {
        var result: [String: String] = [:]
        for contract in contracts {
            guard result.updateValue(contract.schemaHash, forKey: contract.id) == nil else {
                throw PluginAuthorizationError.duplicateCapability(contract.id)
            }
        }
        return result
    }
}

public enum PluginCapabilityRegistryError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidContract(String)
    case duplicatePlugin(String)

    public var description: String {
        switch self {
        case let .invalidContract(id):
            return "plugin capability contract '\(id)' does not match its authorised manifest"
        case let .duplicatePlugin(id):
            return "plugin '\(id)' was enabled more than once"
        }
    }
}

/// Editor-side immutable binding for one package that has been inspected,
/// authorised, and loaded into a particular PluginHost generation.
public struct PluginExecutionBinding: Sendable, Equatable {
    public var pluginPath: String
    public var inspection: PluginInspection
    public var authorization: PluginAuthorizationRecord
    public var hostGeneration: UInt64

    public init(pluginPath: String,
                inspection: PluginInspection,
                authorization: PluginAuthorizationRecord,
                hostGeneration: UInt64) throws {
        guard !pluginPath.isEmpty,
              authorization.isStillValid(for: inspection) else {
            throw PluginAuthorizationError.noLongerValid
        }
        self.pluginPath = pluginPath
        self.inspection = inspection
        self.authorization = authorization
        self.hostGeneration = hostGeneration
    }

    public var pluginID: String { inspection.manifest.id }

    public var authority: PluginCapabilityAuthority {
        PluginCapabilityAuthority(pluginID: pluginID,
                                  authorizationDigest: authorization.authorityDigest,
                                  hostGeneration: hostGeneration)
    }

    public func validate(hostGeneration currentGeneration: UInt64) throws {
        guard currentGeneration == hostGeneration,
              authorization.isStillValid(for: inspection) else {
            throw PluginAuthorizationError.noLongerValid
        }
    }
}

/// Converts authorised WIT-derived contracts into metadata-only Registry
/// descriptors. Plugin code never supplies an executable closure or mutation.
public enum PluginCapabilityRegistryBuilder {
    public static func build(
        base: CapabilityRegistry,
        bindings: [PluginExecutionBinding]
    ) throws -> CapabilityRegistry {
        var pluginIDs: Set<String> = []
        var descriptors: [CapabilityDescriptor] = []
        for binding in bindings {
            guard pluginIDs.insert(binding.pluginID).inserted else {
                throw PluginCapabilityRegistryError.duplicatePlugin(binding.pluginID)
            }
            try binding.validate(hostGeneration: binding.hostGeneration)
            let manifest = binding.inspection.manifest
            let prefix = manifest.id + "."
            for contract in binding.inspection.contracts {
                guard contract.id.hasPrefix(prefix),
                      contract.id.count > prefix.count,
                      contract.version == manifest.version,
                      contract.access == manifest.access,
                      contract.domain == "plugin",
                      contract.releasePhase == .stable,
                      contract.source == .plugin(manifest.id),
                      !contract.access.isWrite || contract.inputSchema.isStrictCapabilityInput else {
                    throw PluginCapabilityRegistryError.invalidContract(contract.id)
                }
                descriptors.append(CapabilityDescriptor(
                    verb: contract.id,
                    releasePhase: contract.releasePhase,
                    requiresConfirmation: contract.access.isWrite,
                    isDestructive: contract.access == .destructiveWrite,
                    domain: contract.domain,
                    version: contract.version,
                    title: contract.title,
                    description: contract.description,
                    access: contract.access,
                    inputSchema: contract.inputSchema,
                    source: contract.source,
                    isAIExposed: true
                ))
            }
        }
        let result = base.appending(descriptors)
        try result.validateIntegrity()
        return result
    }
}

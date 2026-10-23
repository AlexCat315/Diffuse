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
        (package.runtime?.witContract.capabilityInputs ?? []).map { input in
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
    public var componentHash: String?
    public var witHash: String?
    public var resourceHashes: [String: String] = [:]
    public var contracts: [CapabilityContract]

    public init(package: ValidatedPluginPackage,
                contracts: [CapabilityContract]) {
        manifest = package.manifest
        resourceHashes = package.resourceHashes
        componentHash = package.runtime?.componentHash
        witHash = package.runtime?.witHash
        self.contracts = contracts.sorted { $0.id < $1.id }
    }

    public init(manifest: GuavaPluginManifest,
                componentHash: String?,
                witHash: String?,
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
    public var componentHash: String?
    public var witHash: String?
    public var imports: [PluginImportPermission]
    public var access: CapabilityAccess
    public var composableHostCapabilities: [String]
    /// Declared dependencies, bound into the authorization like every other
    /// authority field: changing `requires` invalidates the stored record.
    public var requires: [PluginRequirement]
    public var capabilitySchemaHashes: [String: String]
    public var manifestHash: String
    public var resourceHashes: [String: String]
    public var authorisedAt: Date
    public var host: PluginHostPermissions

    public init(inspection: PluginInspection,
                authorisedAt: Date = Date()) throws {
        let hashes = try Self.schemaHashes(inspection.contracts)
        manifestHash = Self.digest(inspection.manifest)
        resourceHashes = inspection.resourceHashes
        pluginID = inspection.manifest.id
        pluginVersion = inspection.manifest.version
        componentHash = inspection.componentHash
        witHash = inspection.witHash
        imports = inspection.manifest.imports
        access = inspection.manifest.access
        composableHostCapabilities = inspection.manifest.composableHostCapabilities
        requires = inspection.manifest.requires
        host = inspection.manifest.host
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
        return manifestHash == Self.digest(inspection.manifest)
            && resourceHashes == inspection.resourceHashes
            && pluginID == inspection.manifest.id
            && pluginVersion == inspection.manifest.version
            && componentHash == inspection.componentHash
            && witHash == inspection.witHash
            && imports == inspection.manifest.imports
            && access == inspection.manifest.access
            && composableHostCapabilities == inspection.manifest.composableHostCapabilities
            && requires == inspection.manifest.requires
            && host == inspection.manifest.host
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
            "component_hash": componentHash as Any? ?? NSNull(),
            "manifest_hash": manifestHash,
            "resource_hashes": resourceHashes,
            "wit_hash": witHash as Any? ?? NSNull(),
            "imports": imports.map(\.rawValue).sorted(),
            "access": access.rawValue,
            "host": try! JSONSerialization.jsonObject(with: JSONEncoder().encode(host)),
            "composable_host_capabilities": composableHostCapabilities.sorted(),
            "requires": requires.map { requirement -> [String: Any] in
                var entry: [String: Any] = [
                    "kind": requirement.kind.rawValue,
                    "id": requirement.id,
                ]
                if let minimum = requirement.minimumVersion {
                    entry["minimum_version"] = minimum
                }
                return entry
            },
            "capability_schema_hashes": capabilitySchemaHashes,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object,
                                                options: [.sortedKeys])) ?? Data()
        return CapabilityDigest.sha256(data)
    }

    private static func digest(_ manifest: GuavaPluginManifest) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return CapabilityDigest.sha256(try! encoder.encode(manifest))
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
        bindings: [PluginExecutionBinding],
        enabledDeclarations: [PluginInspection] = []
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
                    isAIExposed: manifest.exposesToAI(entryPoint: String(contract.id.dropFirst(prefix.count)))
                ))
            }
        }
        let result = base.appending(descriptors)
        try result.validateIntegrity()
        try validateRequirements(bindings, declarations: enabledDeclarations, base: base)
        return result
    }

    /// Resolve in dependency order even when bindings arrive in another order.
    /// No progress means a missing/versioned dependency or a cycle: either way
    /// the entire registry is rejected before any executor is published.
    private static func validateRequirements(_ bindings: [PluginExecutionBinding],
                                             declarations: [PluginInspection],
                                             base: CapabilityRegistry) throws {
        var remaining = bindings.sorted { $0.pluginID < $1.pluginID }
        // Runtime dependencies are activated first by PluginManager. Pure
        // declarations can satisfy package requirements without a binding.
        var plugins = Dictionary(uniqueKeysWithValues: declarations.filter { $0.componentHash == nil }.map {
            ($0.manifest.id, $0.manifest.version)
        })
        var capabilities = Dictionary(uniqueKeysWithValues: base.allVerbs().compactMap { id in
            base.descriptor(for: id).map { (id, $0.version) }
        })
        while !remaining.isEmpty {
            let index = remaining.firstIndex { binding in
                PluginRequirementResolver.unmet(
                    binding.inspection.manifest.requires, requiredBy: binding.pluginID,
                    enabledPlugins: plugins, providedCapabilities: capabilities
                ).isEmpty
            }
            guard let index else {
                let binding = remaining[0]
                throw UnmetPluginRequirements(pluginID: binding.pluginID, violations:
                    PluginRequirementResolver.unmet(
                        binding.inspection.manifest.requires, requiredBy: binding.pluginID,
                        enabledPlugins: plugins, providedCapabilities: capabilities
                    ))
            }
            let binding = remaining.remove(at: index)
            plugins[binding.pluginID] = binding.inspection.manifest.version
            for contract in binding.inspection.contracts {
                capabilities[contract.id] = contract.version
            }
        }
    }
}

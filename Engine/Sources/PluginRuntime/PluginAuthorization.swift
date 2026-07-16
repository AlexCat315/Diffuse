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

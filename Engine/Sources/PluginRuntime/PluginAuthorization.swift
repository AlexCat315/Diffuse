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

public enum PluginDiscoveryValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidPayload
    case tooManyCapabilities
    case duplicateCapability(String)
    case missingImplementation(String)
    case undeclaredImplementation(String)

    public var description: String {
        switch self {
        case .invalidPayload:
            return "plugin discovery must be exactly {\"capability_ids\":[...]}"
        case .tooManyCapabilities: return "plugin discovery exceeds the 64 capability limit"
        case let .duplicateCapability(id): return "plugin discovery contains duplicate capability '\(id)'"
        case let .missingImplementation(id):
            return "WIT capability '\(id)' is not implemented by the Component"
        case let .undeclaredImplementation(id):
            return "Component implements capability '\(id)' that is absent from WIT"
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

/// The Component only proves that it implements the exact capability IDs
/// declared by WIT. It cannot supply title, access, schema, version, source, or
/// a schema hash, so discovery cannot be used to increase authority.
public enum PluginDiscoveryValidator {
    public static func validate(_ data: Data,
                                package: ValidatedPluginPackage,
                                limits: PluginResourceLimits = .secureDefault) throws -> [CapabilityContract] {
        guard data.count <= limits.maximumOutputBytes,
              let value = try? JSONSerialization.jsonObject(with: data),
              let object = value as? [String: Any],
              Set(object.keys) == Set(["capability_ids"]),
              let rawIDs = object["capability_ids"] as? [Any],
              rawIDs.allSatisfy({ $0 is String }) else {
            throw PluginDiscoveryValidationError.invalidPayload
        }
        let ids = rawIDs.compactMap { $0 as? String }
        guard ids.count <= limits.maximumCapabilities else {
            throw PluginDiscoveryValidationError.tooManyCapabilities
        }
        var seen: Set<String> = []
        for id in ids {
            guard let range = id.range(of: #"^[a-z][a-z0-9.-]{2,127}$"#,
                                       options: .regularExpression),
                  range == id.startIndex..<id.endIndex else {
                throw PluginDiscoveryValidationError.invalidPayload
            }
            guard seen.insert(id).inserted else {
                throw PluginDiscoveryValidationError.duplicateCapability(id)
            }
        }
        let contracts = PluginWITContractDeriver.contracts(for: package)
        let expected = Set(contracts.map(\.id))
        if let missing = expected.subtracting(seen).sorted().first {
            throw PluginDiscoveryValidationError.missingImplementation(missing)
        }
        if let undeclared = seen.subtracting(expected).sorted().first {
            throw PluginDiscoveryValidationError.undeclaredImplementation(undeclared)
        }
        return contracts
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

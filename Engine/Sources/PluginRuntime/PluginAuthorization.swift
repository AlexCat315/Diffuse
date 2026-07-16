import CapabilityRuntime
import Foundation

public struct PluginCapabilityDiscovery: Codable, Sendable, Equatable {
    public var capabilities: [CapabilityContract]

    public init(capabilities: [CapabilityContract]) {
        self.capabilities = capabilities.sorted { $0.id < $1.id }
    }
}

public enum PluginDiscoveryValidationError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidPayload
    case tooManyCapabilities
    case duplicateCapability(String)
    case invalidIdentifier(String)
    case invalidVersion(String)
    case invalidDomain(String)
    case emptyTitle(String)
    case sourceMismatch(String)
    case accessExceedsManifest(String)
    case externalSideEffectDisabled(String)
    case unstableRelease(String)
    case schemaMustBeStrict(String)
    case unsafeSchema(String, String)
    case schemaHashMismatch(String)

    public var description: String {
        switch self {
        case .invalidPayload: return "plugin discovery is not a valid capability envelope"
        case .tooManyCapabilities: return "plugin discovery exceeds the 64 capability limit"
        case let .duplicateCapability(id): return "plugin discovery contains duplicate capability '\(id)'"
        case let .invalidIdentifier(id): return "plugin capability has an invalid or foreign id '\(id)'"
        case let .invalidVersion(id): return "plugin capability '\(id)' has an invalid version"
        case let .invalidDomain(id): return "plugin capability '\(id)' has an invalid domain"
        case let .emptyTitle(id): return "plugin capability '\(id)' has an empty title"
        case let .sourceMismatch(id): return "plugin capability '\(id)' has a forged source"
        case let .accessExceedsManifest(id): return "plugin capability '\(id)' exceeds manifest access"
        case let .externalSideEffectDisabled(id): return "plugin capability '\(id)' requests external side effects"
        case let .unstableRelease(id): return "plugin capability '\(id)' is not stable"
        case let .schemaMustBeStrict(id): return "plugin capability '\(id)' must use a strict object input schema"
        case let .unsafeSchema(id, reason): return "plugin capability '\(id)' has an unsafe schema: \(reason)"
        case let .schemaHashMismatch(id): return "plugin capability '\(id)' supplied an invalid schema hash"
        }
    }
}

/// Converts untrusted Component discovery JSON into canonical host contracts.
/// A plugin cannot pick another source, escape its id namespace, understate its
/// access, or provide a schema hash computed over different metadata.
public enum PluginDiscoveryValidator {
    public static func validate(_ data: Data,
                                package: ValidatedPluginPackage,
                                limits: PluginResourceLimits = .secureDefault) throws -> [CapabilityContract] {
        guard data.count <= limits.maximumOutputBytes,
              let discovery = try? JSONDecoder().decode(PluginCapabilityDiscovery.self,
                                                        from: data) else {
            throw PluginDiscoveryValidationError.invalidPayload
        }
        guard discovery.capabilities.count <= limits.maximumCapabilities else {
            throw PluginDiscoveryValidationError.tooManyCapabilities
        }
        var seen: Set<String> = []
        var canonical: [CapabilityContract] = []
        canonical.reserveCapacity(discovery.capabilities.count)
        let namespace = package.manifest.id + "."
        for contract in discovery.capabilities {
            guard seen.insert(contract.id).inserted else {
                throw PluginDiscoveryValidationError.duplicateCapability(contract.id)
            }
            guard contract.id.hasPrefix(namespace),
                  contract.id.count > namespace.count,
                  contract.id.range(
                    of: #"^[a-z][a-z0-9.-]{2,127}$"#,
                    options: .regularExpression
                  ) != nil else {
                throw PluginDiscoveryValidationError.invalidIdentifier(contract.id)
            }
            guard contract.version > 0 else {
                throw PluginDiscoveryValidationError.invalidVersion(contract.id)
            }
            guard contract.domain.range(
                of: #"^[a-z][a-z0-9_.-]{0,63}$"#,
                options: .regularExpression
            ) != nil else {
                throw PluginDiscoveryValidationError.invalidDomain(contract.id)
            }
            guard !CapabilityContract.sanitiseMetadata(contract.title, maximumLength: 80)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw PluginDiscoveryValidationError.emptyTitle(contract.id)
            }
            guard contract.source == .plugin(package.manifest.id) else {
                throw PluginDiscoveryValidationError.sourceMismatch(contract.id)
            }
            guard riskRank(contract.access) <= riskRank(package.manifest.access) else {
                throw PluginDiscoveryValidationError.accessExceedsManifest(contract.id)
            }
            guard contract.access != .externalSideEffect else {
                throw PluginDiscoveryValidationError.externalSideEffectDisabled(contract.id)
            }
            guard contract.releasePhase == .stable else {
                throw PluginDiscoveryValidationError.unstableRelease(contract.id)
            }
            guard contract.inputSchema.type == .object,
                  contract.inputSchema.isStrictCapabilityInput else {
                throw PluginDiscoveryValidationError.schemaMustBeStrict(contract.id)
            }
            do {
                var nodeCount = 0
                try validateSchema(contract.inputSchema,
                                   depth: 0,
                                   nodeCount: &nodeCount)
            } catch let reason as PluginSchemaSafetyError {
                throw PluginDiscoveryValidationError.unsafeSchema(
                    contract.id,
                    reason.description
                )
            }
            let normalized = CapabilityContract(
                id: contract.id,
                version: contract.version,
                title: contract.title,
                description: contract.description,
                domain: contract.domain,
                access: contract.access,
                releasePhase: contract.releasePhase,
                inputSchema: contract.inputSchema,
                source: .plugin(package.manifest.id)
            )
            guard contract.schemaHash == normalized.schemaHash else {
                throw PluginDiscoveryValidationError.schemaHashMismatch(contract.id)
            }
            canonical.append(normalized)
        }
        return canonical.sorted { $0.id < $1.id }
    }

    private static func riskRank(_ access: CapabilityAccess) -> Int {
        switch access {
        case .read: return 0
        case .reversibleWrite: return 1
        case .destructiveWrite: return 2
        case .externalSideEffect: return 3
        }
    }

    private static func validateSchema(_ schema: JSONSchema,
                                       depth: Int,
                                       nodeCount: inout Int) throws {
        guard depth <= 12 else { throw PluginSchemaSafetyError.tooDeep }
        nodeCount += 1
        guard nodeCount <= 256 else { throw PluginSchemaSafetyError.tooManyNodes }
        if let description = schema.description,
           description != CapabilityContract.sanitiseMetadata(description,
                                                               maximumLength: 512) {
            throw PluginSchemaSafetyError.unsafeDescription
        }
        guard schema.allowedValues.count <= 128 else {
            throw PluginSchemaSafetyError.tooManyEnumValues
        }
        for value in schema.allowedValues {
            switch value {
            case let .string(string) where string.utf8.count > 1_024:
                throw PluginSchemaSafetyError.enumValueTooLarge
            case let .number(number) where !number.isFinite:
                throw PluginSchemaSafetyError.nonFiniteNumber
            default:
                break
            }
        }

        if !schema.oneOf.isEmpty {
            guard schema.type == nil,
                  schema.oneOf.count <= 8,
                  schema.properties.isEmpty,
                  schema.required.isEmpty,
                  schema.items.isEmpty,
                  schema.allowedValues.isEmpty,
                  schema.additionalProperties == nil,
                  hasNoNumericOrCollectionConstraints(schema) else {
                throw PluginSchemaSafetyError.mixedSchemaKinds
            }
            for alternative in schema.oneOf {
                try validateSchema(alternative,
                                   depth: depth + 1,
                                   nodeCount: &nodeCount)
            }
            return
        }

        switch schema.type {
        case .object:
            guard schema.additionalProperties == false,
                  schema.properties.count <= 64,
                  schema.items.isEmpty,
                  schema.allowedValues.isEmpty,
                  hasNoNumericOrCollectionConstraints(schema) else {
                throw PluginSchemaSafetyError.invalidObject
            }
            let required = Set(schema.required)
            guard required.count == schema.required.count,
                  required.isSubset(of: Set(schema.properties.keys)) else {
                throw PluginSchemaSafetyError.invalidRequiredProperties
            }
            for (name, child) in schema.properties {
                guard name.range(
                    of: #"^[A-Za-z][A-Za-z0-9_-]{0,63}$"#,
                    options: .regularExpression
                ) != nil else {
                    throw PluginSchemaSafetyError.invalidPropertyName
                }
                try validateSchema(child,
                                   depth: depth + 1,
                                   nodeCount: &nodeCount)
            }
        case .array:
            guard schema.items.count == 1,
                  schema.properties.isEmpty,
                  schema.required.isEmpty,
                  schema.allowedValues.isEmpty,
                  schema.additionalProperties == nil,
                  schema.minimum == nil,
                  schema.maximum == nil,
                  schema.minimumLength == nil,
                  schema.maximumLength == nil,
                  schema.pattern == nil,
                  validBounds(schema.minimumItems,
                              schema.maximumItems,
                              absoluteMaximum: 4_096) else {
                throw PluginSchemaSafetyError.invalidArray
            }
            try validateSchema(schema.items[0],
                               depth: depth + 1,
                               nodeCount: &nodeCount)
        case .string:
            guard hasNoChildren(schema),
                  schema.minimum == nil,
                  schema.maximum == nil,
                  schema.minimumItems == nil,
                  schema.maximumItems == nil,
                  schema.pattern == nil,
                  validBounds(schema.minimumLength,
                              schema.maximumLength,
                              absoluteMaximum: 65_536),
                  schema.allowedValues.allSatisfy({
                      if case .string = $0 { return true }
                      return false
                  }) else {
                throw PluginSchemaSafetyError.invalidString
            }
        case .number, .integer:
            guard hasNoChildren(schema),
                  schema.minimumItems == nil,
                  schema.maximumItems == nil,
                  schema.minimumLength == nil,
                  schema.maximumLength == nil,
                  schema.pattern == nil,
                  validNumericBounds(schema.minimum, schema.maximum),
                  schema.allowedValues.allSatisfy({
                      if case .number = $0 { return true }
                      return false
                  }) else {
                throw PluginSchemaSafetyError.invalidNumber
            }
        case .boolean:
            guard hasNoChildren(schema),
                  hasNoNumericOrCollectionConstraints(schema),
                  schema.allowedValues.allSatisfy({
                      if case .boolean = $0 { return true }
                      return false
                  }) else {
                throw PluginSchemaSafetyError.invalidBoolean
            }
        case .null:
            guard hasNoChildren(schema),
                  hasNoNumericOrCollectionConstraints(schema),
                  schema.allowedValues.isEmpty else {
                throw PluginSchemaSafetyError.invalidNull
            }
        case nil:
            throw PluginSchemaSafetyError.untypedValue
        }
    }

    private static func hasNoChildren(_ schema: JSONSchema) -> Bool {
        schema.properties.isEmpty
            && schema.required.isEmpty
            && schema.items.isEmpty
            && schema.oneOf.isEmpty
            && schema.additionalProperties == nil
    }

    private static func hasNoNumericOrCollectionConstraints(_ schema: JSONSchema) -> Bool {
        schema.minimum == nil
            && schema.maximum == nil
            && schema.minimumItems == nil
            && schema.maximumItems == nil
            && schema.minimumLength == nil
            && schema.maximumLength == nil
            && schema.pattern == nil
    }

    private static func validBounds(_ minimum: Int?,
                                    _ maximum: Int?,
                                    absoluteMaximum: Int) -> Bool {
        if let minimum, minimum < 0 { return false }
        if let maximum, maximum < 0 || maximum > absoluteMaximum { return false }
        if let minimum, let maximum, minimum > maximum { return false }
        return true
    }

    private static func validNumericBounds(_ minimum: Double?,
                                           _ maximum: Double?) -> Bool {
        if let minimum, !minimum.isFinite { return false }
        if let maximum, !maximum.isFinite { return false }
        if let minimum, let maximum, minimum > maximum { return false }
        return true
    }
}

private enum PluginSchemaSafetyError: Error, CustomStringConvertible {
    case tooDeep, tooManyNodes, unsafeDescription, tooManyEnumValues
    case enumValueTooLarge, nonFiniteNumber, mixedSchemaKinds
    case invalidObject, invalidRequiredProperties, invalidPropertyName
    case invalidArray, invalidString, invalidNumber, invalidBoolean, invalidNull
    case untypedValue

    var description: String {
        switch self {
        case .tooDeep: return "schema nesting exceeds 12 levels"
        case .tooManyNodes: return "schema exceeds 256 nodes"
        case .unsafeDescription: return "field description is unsanitised or exceeds 512 characters"
        case .tooManyEnumValues: return "enum exceeds 128 values"
        case .enumValueTooLarge: return "enum string exceeds 1024 bytes"
        case .nonFiniteNumber: return "numeric constraint is not finite"
        case .mixedSchemaKinds: return "oneOf mixes incompatible schema keywords"
        case .invalidObject: return "object is open or contains incompatible constraints"
        case .invalidRequiredProperties: return "required keys are duplicated or missing from properties"
        case .invalidPropertyName: return "property name is outside the supported identifier subset"
        case .invalidArray: return "array constraints are invalid or exceed 4096 items"
        case .invalidString: return "string constraints are invalid; plugin regex patterns are disabled"
        case .invalidNumber: return "numeric constraints or enum values are invalid"
        case .invalidBoolean: return "boolean constraints or enum values are invalid"
        case .invalidNull: return "null schema contains incompatible constraints"
        case .untypedValue: return "untyped JSON values are disabled"
        }
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

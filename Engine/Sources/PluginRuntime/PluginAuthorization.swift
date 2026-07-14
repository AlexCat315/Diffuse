import CapabilityRuntime
import Foundation

public struct PluginAuthorizationRecord: Codable, Sendable, Equatable {
    public var pluginID: String
    public var pluginVersion: Int
    public var witHash: String
    public var imports: [PluginImportPermission]
    public var composableHostCapabilities: [String]
    public var capabilitySchemaHashes: [String: String]
    public var authorisedAt: Date

    public init(package: ValidatedPluginPackage,
                contracts: [CapabilityContract],
                authorisedAt: Date = Date()) throws {
        pluginID = package.manifest.id
        pluginVersion = package.manifest.version
        witHash = package.witHash
        imports = package.manifest.imports
        composableHostCapabilities = package.manifest.composableHostCapabilities
        capabilitySchemaHashes = Dictionary(uniqueKeysWithValues: contracts.map { ($0.id, $0.schemaHash) })
        self.authorisedAt = authorisedAt
    }

    public func isStillValid(for package: ValidatedPluginPackage,
                             contracts: [CapabilityContract]) -> Bool {
        guard pluginID == package.manifest.id,
              pluginVersion == package.manifest.version,
              imports == package.manifest.imports,
              composableHostCapabilities == package.manifest.composableHostCapabilities,
              witHash == package.witHash else { return false }
        return capabilitySchemaHashes == Dictionary(uniqueKeysWithValues: contracts.map {
            ($0.id, $0.schemaHash)
        })
    }
}

import CapabilityRuntime
import Foundation
private import CoveFileSystem

public struct ValidatedPluginPackage: Sendable, Equatable {
    public var rootURL: URL
    public var manifest: CovePluginManifest
    public var runtime: ValidatedPluginRuntime?
    public var resourceHashes: [String: String] = [:]

    public func requireRuntime() throws -> ValidatedPluginRuntime {
        guard let runtime else { throw PluginPackageError.runtimeRequired }
        return runtime
    }

    public func resource(at path: String) throws -> Data {
        let data = try PluginPackageResources.read(path, beneath: rootURL)
        guard resourceHashes[path] == CapabilityDigest.sha256(data) else {
            throw PluginAuthorizationError.noLongerValid
        }
        return data
    }
}

public struct ValidatedPluginRuntime: Sendable, Equatable {
    public var entryURL: URL
    public var contractURL: URL
    public var contract: PluginContract
    public var codeHash: String
    public var contractHash: String
}

public enum PluginPackageError: Error, Sendable, Equatable, CustomStringConvertible {
    case invalidExtension
    case packageNotDirectory
    case missingFile(String)
    case symbolicLinkNotAllowed(String)
    case componentTooLarge
    case invalidComponentHeader
    case unexpectedFile(String)
    case incompleteRuntime
    case runtimeRequired
    case invalidResource(String)

    public var description: String {
        switch self {
        case .invalidExtension: return "plugin package must end in .coveplugin"
        case .packageNotDirectory: return "plugin package is not a directory"
        case let .missingFile(name): return "plugin package is missing \(name)"
        case let .symbolicLinkNotAllowed(name): return "symbolic links are not allowed for \(name)"
        case .componentTooLarge: return "plugin.js exceeds the package size limit"
        case .invalidComponentHeader: return "plugin.js must contain UTF-8 JavaScript"
        case let .unexpectedFile(name): return "unexpected file in plugin package: \(name)"
        case .incompleteRuntime: return "plugin.js and capabilities.json must both be present"
        case .runtimeRequired: return "this operation requires a plugin runtime"
        case let .invalidResource(path): return "invalid plugin resource: \(path)"
        }
    }
}

public struct PluginPackageLoader: Sendable {
    public var registry: CapabilityRegistry
    public var maximumCodeBytes: Int
    private let contributionPoints: ContributionPointRegistry

    public init(registry: CapabilityRegistry = .default,
                maximumCodeBytes: Int = 128 * 1_024 * 1_024,
                contributionPoints: ContributionPointRegistry = .standard) {
        self.registry = registry
        self.maximumCodeBytes = min(maximumCodeBytes, 128 * 1_024 * 1_024)
        self.contributionPoints = contributionPoints
    }

    public func load(at packageURL: URL) throws -> ValidatedPluginPackage {
        let root = packageURL.standardizedFileURL
        guard root.pathExtension == "coveplugin" else { throw PluginPackageError.invalidExtension }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw PluginPackageError.packageNotDirectory }
        let rootValues = try? root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard rootValues?.isSymbolicLink != true else {
            throw PluginPackageError.symbolicLinkNotAllowed(root.lastPathComponent)
        }
        let allowedNames: Set<String> = ["plugin.json", "plugin.js", "capabilities.json", "resources"]
        let children = try FileManager.default.contentsOfDirectory(at: root,
                                                                  includingPropertiesForKeys: nil)
        if let unexpected = children.first(where: { !allowedNames.contains($0.lastPathComponent) }) {
            throw PluginPackageError.unexpectedFile(unexpected.lastPathComponent)
        }

        let manifestURL = try fixedFile("plugin.json", beneath: root)
        let manifest = try PluginManifestValidator.decodeAndValidate(Data(contentsOf: manifestURL),
                                                                     registry: registry,
                                                                     contributions: contributionPoints)
        let resources = try PluginPackageResources.load(manifest.resources, beneath: root)
        for theme in try manifest.contributes.decode(ThemeContributionPoint.self) {
            guard manifest.resources.contains(where: { $0.path == theme.path && $0.kind == "theme" }) else {
                throw PluginPackageError.invalidResource(theme.path)
            }
        }
        let names = Set(children.map(\.lastPathComponent))
        let hasComponent = names.contains("plugin.js")
        guard hasComponent == names.contains("capabilities.json") else { throw PluginPackageError.incompleteRuntime }
        guard hasComponent else {
            guard manifest.runtime == nil, manifest.imports.isEmpty, manifest.host.processes.isEmpty,
                  manifest.composableHostCapabilities.isEmpty, manifest.activation.isEmpty,
                  manifest.access == .read else { throw PluginPackageError.runtimeRequired }
            try manifest.contributes.validateRuntime(nil, in: contributionPoints)
            return ValidatedPluginPackage(rootURL: root, manifest: manifest, runtime: nil, resourceHashes: resources)
        }
        guard manifest.runtime != nil else { throw PluginPackageError.runtimeRequired }
        let entryURL = try fixedFile("plugin.js", beneath: root)
        let contractURL = try fixedFile("capabilities.json", beneath: root)
        let componentData = try Data(contentsOf: entryURL, options: [.mappedIfSafe])
        guard componentData.count <= maximumCodeBytes else { throw PluginPackageError.componentTooLarge }
        guard !componentData.isEmpty, String(data: componentData, encoding: .utf8) != nil else {
            throw PluginPackageError.invalidComponentHeader
        }
        let witData = try Data(contentsOf: contractURL)
        let wit = try BunPluginContract.decode(witData, imports: manifest.imports)
        guard manifest.host.entryPoints.isSubset(of: Set(wit.capabilityInputs.map(\.name))) else {
            throw PluginManifestValidationError.invalidHostPermissions
        }
        try manifest.contributes.validateRuntime(wit, in: contributionPoints)
        for input in wit.capabilityInputs {
            let capabilityID = manifest.id + "." + input.name
            guard let range = capabilityID.range(
                of: #"^[a-z][a-z0-9.-]{2,127}$"#,
                options: .regularExpression
            ), range == capabilityID.startIndex..<capabilityID.endIndex else {
                throw PluginContractError.invalidCapabilityName(capabilityID)
            }
        }
        return ValidatedPluginPackage(rootURL: root,
                                      manifest: manifest,
                                      runtime: ValidatedPluginRuntime(entryURL: entryURL,
                                      contractURL: contractURL,
                                      contract: wit,
                                      codeHash: CapabilityDigest.sha256(componentData),
                                      contractHash: CapabilityDigest.sha256(witData)), resourceHashes: resources)
    }

    private func fixedFile(_ name: String, beneath root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        guard PathIdentity.sameLocation(url.deletingLastPathComponent(), root) else {
            throw PluginPackageError.missingFile(name)
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw PluginPackageError.symbolicLinkNotAllowed(name) }
        guard values?.isRegularFile == true else { throw PluginPackageError.missingFile(name) }
        return url
    }

}

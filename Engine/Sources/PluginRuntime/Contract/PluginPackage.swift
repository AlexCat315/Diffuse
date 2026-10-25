import CapabilityRuntime
import Foundation
private import GuavaFileSystem

public struct ValidatedPluginPackage: Sendable, Equatable {
    public var rootURL: URL
    public var manifest: GuavaPluginManifest
    public var runtime: ValidatedPluginComponent?
    public var resourceHashes: [String: String] = [:]

    public func requireRuntime() throws -> ValidatedPluginComponent {
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

public struct ValidatedPluginComponent: Sendable, Equatable {
    public var componentURL: URL
    public var witURL: URL
    public var witContract: WITContract
    public var componentHash: String
    public var witHash: String
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
        case .invalidExtension: return "plugin package must end in .guavaplugin"
        case .packageNotDirectory: return "plugin package is not a directory"
        case let .missingFile(name): return "plugin package is missing \(name)"
        case let .symbolicLinkNotAllowed(name): return "symbolic links are not allowed for \(name)"
        case .componentTooLarge: return "component.wasm exceeds the package size limit"
        case .invalidComponentHeader: return "component.wasm does not have a WebAssembly header"
        case let .unexpectedFile(name): return "unexpected file in plugin package: \(name)"
        case .incompleteRuntime: return "component.wasm and capabilities.wit must both be present"
        case .runtimeRequired: return "this operation requires a plugin runtime"
        case let .invalidResource(path): return "invalid plugin resource: \(path)"
        }
    }
}

public struct PluginPackageLoader: Sendable {
    public var registry: CapabilityRegistry
    public var maximumComponentBytes: Int
    private let contributionPoints: ContributionPointRegistry

    public init(registry: CapabilityRegistry = .default,
                maximumComponentBytes: Int = 128 * 1_024 * 1_024,
                contributionPoints: ContributionPointRegistry = .standard) {
        self.registry = registry
        self.maximumComponentBytes = min(maximumComponentBytes, 128 * 1_024 * 1_024)
        self.contributionPoints = contributionPoints
    }

    public func load(at packageURL: URL) throws -> ValidatedPluginPackage {
        let root = packageURL.standardizedFileURL
        guard root.pathExtension == "guavaplugin" else { throw PluginPackageError.invalidExtension }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { throw PluginPackageError.packageNotDirectory }
        let rootValues = try? root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard rootValues?.isSymbolicLink != true else {
            throw PluginPackageError.symbolicLinkNotAllowed(root.lastPathComponent)
        }
        let allowedNames: Set<String> = ["plugin.json", "component.wasm", "capabilities.wit", "resources"]
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
        let hasComponent = names.contains("component.wasm")
        guard hasComponent == names.contains("capabilities.wit") else { throw PluginPackageError.incompleteRuntime }
        guard hasComponent else {
            guard manifest.runtime == nil, manifest.imports.isEmpty, manifest.host.processes.isEmpty,
                  manifest.composableHostCapabilities.isEmpty, manifest.activation.isEmpty,
                  manifest.access == .read else { throw PluginPackageError.runtimeRequired }
            try manifest.contributes.validateRuntime(nil, in: contributionPoints)
            return ValidatedPluginPackage(rootURL: root, manifest: manifest, runtime: nil, resourceHashes: resources)
        }
        let componentURL = try fixedFile("component.wasm", beneath: root)
        let witURL = try fixedFile("capabilities.wit", beneath: root)
        let componentData = try Data(contentsOf: componentURL, options: [.mappedIfSafe])
        guard componentData.count <= maximumComponentBytes else { throw PluginPackageError.componentTooLarge }
        // Component Model binaries use the standard wasm magic followed by
        // version header 0x0d 0x00 0x01 0x00. Reject ordinary core modules.
        guard componentData.count >= 8,
              componentData.prefix(8).elementsEqual([0x00, 0x61, 0x73, 0x6D,
                                                      0x0D, 0x00, 0x01, 0x00]) else {
            throw PluginPackageError.invalidComponentHeader
        }
        let witData = try Data(contentsOf: witURL)
        let wit = try WITContractParser.parse(witData,
                                              grantedImports: Set(manifest.imports))
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
                throw WITContractError.invalidCapabilityName(capabilityID)
            }
        }
        return ValidatedPluginPackage(rootURL: root,
                                      manifest: manifest,
                                      runtime: ValidatedPluginComponent(componentURL: componentURL,
                                      witURL: witURL,
                                      witContract: wit,
                                      componentHash: CapabilityDigest.sha256(componentData),
                                      witHash: CapabilityDigest.sha256(witData)), resourceHashes: resources)
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

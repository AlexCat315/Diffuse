import CapabilityRuntime
import Foundation

public struct ValidatedPluginPackage: Sendable, Equatable {
    public var rootURL: URL
    public var manifest: GuavaPluginManifest
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

    public var description: String {
        switch self {
        case .invalidExtension: return "plugin package must end in .guavaplugin"
        case .packageNotDirectory: return "plugin package is not a directory"
        case let .missingFile(name): return "plugin package is missing \(name)"
        case let .symbolicLinkNotAllowed(name): return "symbolic links are not allowed for \(name)"
        case .componentTooLarge: return "component.wasm exceeds the package size limit"
        case .invalidComponentHeader: return "component.wasm does not have a WebAssembly header"
        case let .unexpectedFile(name): return "unexpected file in plugin package: \(name)"
        }
    }
}

public struct PluginPackageLoader: Sendable {
    public var registry: CapabilityRegistry
    public var maximumComponentBytes: Int

    public init(registry: CapabilityRegistry = .default,
                maximumComponentBytes: Int = 128 * 1_024 * 1_024) {
        self.registry = registry
        self.maximumComponentBytes = min(maximumComponentBytes, 128 * 1_024 * 1_024)
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
        let allowedNames: Set<String> = ["plugin.json", "component.wasm", "capabilities.wit"]
        let children = try FileManager.default.contentsOfDirectory(at: root,
                                                                  includingPropertiesForKeys: nil)
        if let unexpected = children.first(where: { !allowedNames.contains($0.lastPathComponent) }) {
            throw PluginPackageError.unexpectedFile(unexpected.lastPathComponent)
        }

        let manifestURL = try fixedFile("plugin.json", beneath: root)
        let componentURL = try fixedFile("component.wasm", beneath: root)
        let witURL = try fixedFile("capabilities.wit", beneath: root)
        let manifest = try PluginManifestValidator.decodeAndValidate(Data(contentsOf: manifestURL),
                                                                     registry: registry)
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
                                      componentURL: componentURL,
                                      witURL: witURL,
                                      witContract: wit,
                                      componentHash: CapabilityDigest.sha256(componentData),
                                      witHash: CapabilityDigest.sha256(witData))
    }

    private func fixedFile(_ name: String, beneath root: URL) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: false).standardizedFileURL
        let parentComponents = comparablePathComponents(url.deletingLastPathComponent())
        guard parentComponents == comparablePathComponents(root) else {
            throw PluginPackageError.missingFile(name)
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isSymbolicLink != true else { throw PluginPackageError.symbolicLinkNotAllowed(name) }
        guard values?.isRegularFile == true else { throw PluginPackageError.missingFile(name) }
        return url
    }

    private func comparablePathComponents(_ url: URL) -> [String] {
        let components = url.standardizedFileURL.pathComponents
        #if os(Windows)
        return components.map { $0.lowercased() }
        #else
        return components
        #endif
    }
}

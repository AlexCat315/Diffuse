import Foundation
import CapabilityRuntime

public struct PluginResource: Codable, Sendable, Equatable {
    public var id: String
    public var path: String
    public var kind: String

    public init(id: String, path: String, kind: String) {
        self.id = id
        self.path = path
        self.kind = kind
    }

    public static func isValidPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.first == "resources" && path.utf8.count <= 512
            && !path.contains("\\") && !path.contains(":") && !path.contains("\0")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
}

public struct PluginRuntimeDeclaration: Codable, Sendable, Equatable {
    public var engine = "bun"
    public var entry = "plugin.js"
    public var compatibility = 1

    public init() {}

    private enum CodingKeys: String, CodingKey { case engine, entry, compatibility }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        engine = try values.decode(String.self, forKey: .engine)
        entry = try values.decode(String.self, forKey: .entry)
        compatibility = try values.decodeIfPresent(Int.self, forKey: .compatibility) ?? compatibility
    }
}

enum PluginPackageResources {
    static let maximumBytes = 16 * 1_024 * 1_024

    static func load(_ resources: [PluginResource], beneath root: URL) throws -> [String: String] {
        var hashes: [String: String] = [:]
        var size = 0
        for resource in resources {
            let data = try read(resource.path, beneath: root)
            size += data.count
            guard size <= maximumBytes else { throw PluginPackageError.invalidResource(resource.path) }
            hashes[resource.path] = CapabilityDigest.sha256(data)
        }
        let resourceRoot = root.appendingPathComponent("resources", isDirectory: true)
        if FileManager.default.fileExists(atPath: resourceRoot.path) {
            try checkDirectory(resourceRoot, prefix: "resources", declared: Set(hashes.keys))
        }
        return hashes
    }

    static func read(_ path: String, beneath root: URL) throws -> Data {
        guard PluginResource.isValidPath(path) else { throw PluginPackageError.invalidResource(path) }
        var url = root
        for part in path.split(separator: "/") {
            url.appendPathComponent(String(part))
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw PluginPackageError.symbolicLinkNotAllowed(path) }
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size <= maximumBytes else {
            throw PluginPackageError.invalidResource(path)
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw PluginPackageError.invalidResource(path) }
        return data
    }

    private static func checkDirectory(_ directory: URL, prefix: String, declared: Set<String>) throws {
        let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true else { throw PluginPackageError.symbolicLinkNotAllowed(directory.lastPathComponent) }
        guard values.isDirectory == true else { throw PluginPackageError.invalidResource(directory.lastPathComponent) }
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            let path = prefix + "/" + url.lastPathComponent
            let entry = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard entry.isSymbolicLink != true else { throw PluginPackageError.symbolicLinkNotAllowed(url.lastPathComponent) }
            if entry.isDirectory == true {
                try checkDirectory(url, prefix: path, declared: declared)
            } else {
                guard declared.contains(path) else { throw PluginPackageError.invalidResource(path) }
            }
        }
    }
}


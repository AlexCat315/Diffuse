import Foundation

public enum MeshTextureResolverError: Error, CustomStringConvertible, Equatable {
    case missingSourceURI
    case unsupportedEmbeddedURI(String)
    case relativeURIWithoutSourceDirectory(String)
    case unsupportedURI(String)

    public var description: String {
        switch self {
        case .missingSourceURI:
            return "texture source uri is missing"
        case let .unsupportedEmbeddedURI(uri):
            return "embedded texture uri is not supported yet: \(uri)"
        case let .relativeURIWithoutSourceDirectory(uri):
            return "relative texture uri requires a source directory: \(uri)"
        case let .unsupportedURI(uri):
            return "unsupported texture uri: \(uri)"
        }
    }
}

public struct ResolvedMeshTexture: Sendable, Equatable {
    public var path: String
    public var texture: DecodedTextureAsset

    public init(path: String, texture: DecodedTextureAsset) {
        self.path = path
        self.texture = texture
    }
}

public enum MeshTextureResolver {
    public static func resolvePath(for texture: MeshTexture, sourceDirectory: String?) throws -> String {
        guard let uri = texture.sourceURI, !uri.isEmpty else {
            throw MeshTextureResolverError.missingSourceURI
        }
        if uri.hasPrefix("data:") {
            throw MeshTextureResolverError.unsupportedEmbeddedURI(uri)
        }

        if let components = URLComponents(string: uri), let scheme = components.scheme {
            guard scheme == "file", let url = components.url else {
                throw MeshTextureResolverError.unsupportedURI(uri)
            }
            return url.path
        }

        if uri.hasPrefix("/") {
            return URL(fileURLWithPath: uri).standardizedFileURL.path
        }

        guard let sourceDirectory, !sourceDirectory.isEmpty else {
            throw MeshTextureResolverError.relativeURIWithoutSourceDirectory(uri)
        }
        return URL(fileURLWithPath: sourceDirectory)
            .appendingPathComponent(uri)
            .standardizedFileURL
            .path
    }

    public static func decode(_ texture: MeshTexture, sourceDirectory: String?) throws -> ResolvedMeshTexture {
        if let uri = texture.sourceURI, uri.hasPrefix("data:") {
            let data = try decodeDataURI(uri)
            return ResolvedMeshTexture(path: uri, texture: try ImageAssetDecoder.decodeRGBA8(data: data, label: uri))
        }
        let path = try resolvePath(for: texture, sourceDirectory: sourceDirectory)
        return ResolvedMeshTexture(path: path, texture: try ImageAssetDecoder.decodeRGBA8(path: path))
    }

    private static func decodeDataURI(_ uri: String) throws -> Data {
        guard let comma = uri.firstIndex(of: ",") else {
            throw MeshTextureResolverError.unsupportedEmbeddedURI(uri)
        }
        let metadata = uri[..<comma]
        let payload = String(uri[uri.index(after: comma)...])
        if metadata.contains(";base64") {
            guard let data = Data(base64Encoded: payload) else {
                throw MeshTextureResolverError.unsupportedEmbeddedURI(uri)
            }
            return data
        }
        guard let decoded = payload.removingPercentEncoding else {
            throw MeshTextureResolverError.unsupportedEmbeddedURI(uri)
        }
        return Data(decoded.utf8)
    }
}

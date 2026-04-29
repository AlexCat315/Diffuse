import AssetPipeline
import Foundation

public struct MeshDecodedTexture: Sendable, Equatable {
    public var textureIndex: Int
    public var sourcePath: String
    public var texture: DecodedTextureAsset

    public init(textureIndex: Int, sourcePath: String, texture: DecodedTextureAsset) {
        self.textureIndex = textureIndex
        self.sourcePath = sourcePath
        self.texture = texture
    }
}

public struct MeshTextureDecodeFailure: Sendable, Equatable {
    public var textureIndex: Int
    public var sourceURI: String?
    public var reason: String

    public init(textureIndex: Int, sourceURI: String?, reason: String) {
        self.textureIndex = textureIndex
        self.sourceURI = sourceURI
        self.reason = reason
    }
}

public struct MeshTextureRegistrationReport: Sendable, Equatable {
    public var decodedTextures: [MeshDecodedTexture]
    public var failures: [MeshTextureDecodeFailure]

    public init(decodedTextures: [MeshDecodedTexture], failures: [MeshTextureDecodeFailure]) {
        self.decodedTextures = decodedTextures
        self.failures = failures
    }
}

/// Process-wide decoded texture cache for imported mesh assets. RenderBackend
/// fills this beside mesh/material registration so later GPU upload paths can
/// build texture resources without reaching back into AssetRegistry.
public final class MeshTextureRegistry: @unchecked Sendable {
    public static let shared = MeshTextureRegistry()

    private let lock = NSLock()
    private var storage: [Int: MeshTextureRegistrationReport] = [:]

    private init() {}

    @discardableResult
    public func register(meshIndex: Int,
                         mesh: MeshAsset,
                         sourceDirectory: String?) -> MeshTextureRegistrationReport {
        var decodedTextures: [MeshDecodedTexture] = []
        var failures: [MeshTextureDecodeFailure] = []
        for (textureIndex, texture) in mesh.textures.enumerated() {
            do {
                let resolved = try MeshTextureResolver.decode(texture, sourceDirectory: sourceDirectory)
                decodedTextures.append(MeshDecodedTexture(textureIndex: textureIndex,
                                                          sourcePath: resolved.path,
                                                          texture: resolved.texture))
            } catch {
                failures.append(MeshTextureDecodeFailure(textureIndex: textureIndex,
                                                         sourceURI: texture.sourceURI,
                                                         reason: String(describing: error)))
            }
        }

        let report = MeshTextureRegistrationReport(decodedTextures: decodedTextures,
                                                   failures: failures)
        lock.lock()
        storage[meshIndex] = report
        lock.unlock()
        return report
    }

    public func textures(for meshIndex: Int) -> MeshTextureRegistrationReport? {
        lock.lock()
        let value = storage[meshIndex]
        lock.unlock()
        return value
    }

    public func clearAll() {
        lock.lock()
        storage.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

import AssetPipeline
import Foundation

public struct MeshMaterialSet: Sendable, Equatable {
    public var materials: [MeshMaterial]
    public var textures: [MeshTexture]

    public init(materials: [MeshMaterial], textures: [MeshTexture]) {
        self.materials = materials
        self.textures = textures
    }
}

/// Process-wide mesh material metadata cache. RenderBackend fills this when
/// mesh assets are uploaded; later render paths can resolve material and
/// texture metadata by mesh index without reaching back into AssetRegistry.
public final class MeshMaterialRegistry: @unchecked Sendable {
    public static let shared = MeshMaterialRegistry()

    private let lock = NSLock()
    private var storage: [Int: MeshMaterialSet] = [:]

    private init() {}

    public func register(meshIndex: Int, mesh: MeshAsset) {
        register(meshIndex: meshIndex,
                 materials: mesh.materials,
                 textures: mesh.textures)
    }

    public func register(meshIndex: Int,
                         materials: [MeshMaterial],
                         textures: [MeshTexture]) {
        lock.lock()
        storage[meshIndex] = MeshMaterialSet(
            materials: materials.isEmpty ? [MeshMaterial.fallback] : materials,
            textures: textures
        )
        lock.unlock()
    }

    public func materials(for meshIndex: Int) -> MeshMaterialSet? {
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

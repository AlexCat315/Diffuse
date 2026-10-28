import Foundation
import CoveLogging
private import CoveFileSystem
import SIMDCompat

public enum AssetRegistryError: Error, CustomStringConvertible {
    case invalidProjectRoot(String)

    public var description: String {
        switch self {
        case let .invalidProjectRoot(path):
            return "invalid project root: \(path)"
        }
    }
}

public enum ImportableAssetKind: String, Codable, Sendable, Equatable {
    case gltf
    case glb
    case obj
    case dmesh
    case png
    case jpg
    case jpeg
    case webp
    case tga
    case bmp
    case gif
    case svg

    public var sceneKindLabel: String {
        isTexture ? "Texture" : "Static Mesh"
    }

    public var isMesh: Bool {
        switch self {
        case .gltf, .glb, .obj, .dmesh:
            return true
        case .png, .jpg, .jpeg, .webp, .tga, .bmp, .gif, .svg:
            return false
        }
    }

    public var isTexture: Bool {
        switch self {
        case .png, .jpg, .jpeg, .webp, .tga, .bmp, .gif, .svg:
            return true
        case .gltf, .glb, .obj, .dmesh:
            return false
        }
    }
}

public struct AssetRegistryEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let relativePath: String
    public let absolutePath: String
    public let kind: ImportableAssetKind
    public let meshIndex: Int

    public init(id: String,
                name: String,
                relativePath: String,
                absolutePath: String,
                kind: ImportableAssetKind,
                meshIndex: Int) {
        self.id = id
        self.name = name
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.kind = kind
        self.meshIndex = meshIndex
    }
}

public struct RegisteredMeshAsset: Sendable {
    public let meshIndex: Int
    public let assetID: String
    public let kind: ImportableAssetKind
    public let sourceDirectory: String?
    public let mesh: MeshAsset
    public let topologySlices: [MeshTopologySlice]?

    public init(meshIndex: Int,
                assetID: String,
                kind: ImportableAssetKind,
                sourceDirectory: String? = nil,
                mesh: MeshAsset,
                topologySlices: [MeshTopologySlice]? = nil) {
        self.meshIndex = meshIndex
        self.assetID = assetID
        self.kind = kind
        self.sourceDirectory = sourceDirectory
        self.mesh = mesh
        self.topologySlices = topologySlices
    }
}

public final class AssetRegistry: @unchecked Sendable {
    public static let shared = AssetRegistry()
    public static let importedMeshStartIndex = 2

    private let lock = NSLock()
    private var projectRoot: String?
    private var entries: [AssetRegistryEntry] = []
    private var meshes: [Int: RegisteredMeshAsset] = [:]
    /// Explicit transient meshes are an overlay, not part of a project scan.
    /// A catalog reload therefore cannot invalidate one between registration
    /// and consumption.
    private var explicitlyRegisteredMeshes: [Int: RegisteredMeshAsset] = [:]
    /// Stable relativePath → meshIndex map; survives across reloads so indices never change for known paths.
    private var pathIndex: [String: Int] = [:]
    private var nextMeshIndex = importedMeshStartIndex
    private var meshCatalogRevision: UInt64 = 1

    public init() {}

    /// Preserve GPU mesh slots when a project file is renamed or moved.
    public func relocateAssetPath(from oldPath: String, to newPath: String) {
        lock.lock()
        defer { lock.unlock() }
        if let index = pathIndex.removeValue(forKey: oldPath) { pathIndex[newPath] = index }
    }

    @discardableResult
    public func loadProject(at rootPath: String,
                            preferredMeshIndices: [String: Int] = [:]) throws -> [AssetRegistryEntry] {
        let rootURL = PathIdentity.canonicalURL(URL(fileURLWithPath: rootPath, isDirectory: true))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AssetRegistryError.invalidProjectRoot(rootPath)
        }

        let candidates = try findImportableAssets(in: rootURL)
        var loadedEntries: [AssetRegistryEntry] = []
        var loadedMeshes: [Int: RegisteredMeshAsset] = [:]

        lock.lock()
        let isReloadingCurrentProject = projectRoot == rootURL.path
        var currentPathIndex = isReloadingCurrentProject ? pathIndex : [:]
        var currentNextIndex = isReloadingCurrentProject ? nextMeshIndex : Self.importedMeshStartIndex
        let existingMeshes = isReloadingCurrentProject ? meshes : [:]
        lock.unlock()

        // Export bundles persist mesh slots in assets.json. Reserve those slots before
        // assigning new ones so scene references continue to point at the same meshes.
        var usedMeshIndices = Set(currentPathIndex.values)
        for (relativePath, preferredIndex) in preferredMeshIndices.sorted(by: { $0.key < $1.key }) {
            guard preferredIndex >= Self.importedMeshStartIndex,
                  currentPathIndex[relativePath] == nil,
                  !usedMeshIndices.contains(preferredIndex) else { continue }
            currentPathIndex[relativePath] = preferredIndex
            usedMeshIndices.insert(preferredIndex)
            currentNextIndex = max(currentNextIndex, preferredIndex + 1)
        }

        for candidate in candidates {
            let assetURL = PathIdentity.canonicalURL(candidate.url)
            guard let relativePath = Self.relativePath(of: candidate.url, within: rootURL) else {
                LogSystem.logger("com.cove.engine.assets")
                    .warning("AssetRegistry: skipping path outside project root: \(candidate.url.path)")
                continue
            }
            let kind = candidate.kind

            guard kind.isMesh else {
                loadedEntries.append(AssetRegistryEntry(
                    id: relativePath,
                    name: assetURL.deletingPathExtension().lastPathComponent,
                    relativePath: relativePath,
                    absolutePath: assetURL.path,
                    kind: kind,
                    meshIndex: 0
                ))
                continue
            }

            // Reuse existing index for known paths so GPU mesh slots never shift.
            let meshIndex: Int
            if let existing = currentPathIndex[relativePath] {
                meshIndex = existing
                if let existingMesh = existingMeshes[existing], kind != .dmesh {
                    loadedMeshes[meshIndex] = existingMesh
                    loadedEntries.append(AssetRegistryEntry(
                        id: relativePath,
                        name: assetURL.deletingPathExtension().lastPathComponent,
                        relativePath: relativePath,
                        absolutePath: assetURL.path,
                        kind: candidate.kind,
                        meshIndex: meshIndex
                    ))
                    continue
                }
            } else {
                while usedMeshIndices.contains(currentNextIndex) {
                    currentNextIndex += 1
                }
                meshIndex = currentNextIndex
                currentNextIndex += 1
                currentPathIndex[relativePath] = meshIndex
                usedMeshIndices.insert(meshIndex)
            }

            let imported: (mesh: MeshAsset, topologySlices: [MeshTopologySlice]?)
            do {
                imported = try importMesh(at: candidate.url, kind: kind)
            } catch {
                LogSystem.logger("com.cove.engine.assets").warning("AssetRegistry: skipping \(candidate.url.lastPathComponent) — \(error)")
                currentPathIndex.removeValue(forKey: relativePath)
                usedMeshIndices.remove(meshIndex)
                continue
            }
            var mesh = imported.mesh
            // Native authoring assets use scene units; array spacing and shell
            // thickness must survive loading and export without rescaling.
            if kind != .dmesh { mesh.normalizeToUnitBounds(targetSize: 2.0) }

            let normalizedSlices: [MeshTopologySlice]? = {
                if kind == .dmesh { return imported.topologySlices }
                guard let slices = imported.topologySlices else { return nil }
                let src = mesh.localBounds
                let minV = src.min
                let maxV = src.max
                let center = (minV + maxV) * 0.5
                let extent = max(maxV.x - minV.x, max(maxV.y - minV.y, maxV.z - minV.z))
                let scale: Float = extent > 0 ? (2.0 / extent) : 1.0
                return slices.map { slice in
                    let mapped = slice.positions.map { (($0 - center) * scale) }
                    return MeshTopologySlice(positions: mapped,
                                             triangleIndices: slice.triangleIndices,
                                             indexRemap: slice.indexRemap)
                }
            }()

            let entry = AssetRegistryEntry(
                id: relativePath,
                name: assetURL.deletingPathExtension().lastPathComponent,
                relativePath: relativePath,
                absolutePath: assetURL.path,
                kind: kind,
                meshIndex: meshIndex
            )
            loadedEntries.append(entry)
            loadedMeshes[meshIndex] = RegisteredMeshAsset(
                meshIndex: meshIndex,
                assetID: entry.id,
                kind: kind,
                sourceDirectory: assetURL.deletingLastPathComponent().path,
                mesh: mesh,
                topologySlices: normalizedSlices
            )
        }

        lock.lock()
        projectRoot = rootURL.path
        entries = loadedEntries
        meshes = loadedMeshes
        meshCatalogRevision &+= 1
        pathIndex = currentPathIndex
        nextMeshIndex = currentNextIndex
        lock.unlock()
        return loadedEntries
    }

    public func currentProjectRoot() -> String? {
        lock.lock()
        let value = projectRoot
        lock.unlock()
        return value
    }

    public func entriesSnapshot() -> [AssetRegistryEntry] {
        lock.lock()
        let value = entries
        lock.unlock()
        return value
    }

    /// Atomically pairs content with its revision; unchanged frames do not copy
    /// or hash large meshes. Revisions also cover removal and project resets.
    public func meshCatalog(since revision: UInt64?) -> MeshAssetCatalog? {
        lock.lock()
        defer { lock.unlock() }
        guard revision != meshCatalogRevision else { return nil }
        var merged = meshes
        merged.merge(explicitlyRegisteredMeshes) { _, overlay in overlay }
        return MeshAssetCatalog(revision: meshCatalogRevision,
            meshes: merged.values.sorted { $0.meshIndex < $1.meshIndex })
    }

    public func registeredMeshes() -> [RegisteredMeshAsset] {
        lock.lock()
        var merged = meshes
        for (index, registered) in explicitlyRegisteredMeshes {
            merged[index] = registered
        }
        let value = merged.values.sorted { $0.meshIndex < $1.meshIndex }
        lock.unlock()
        return value
    }

    public func entry(for id: String) -> AssetRegistryEntry? {
        lock.lock()
        let value = entries.first { $0.id == id }
        lock.unlock()
        return value
    }

    public func meshAsset(for meshIndex: Int) -> MeshAsset? {
        lock.lock()
        let value = explicitlyRegisteredMeshes[meshIndex]?.mesh ?? meshes[meshIndex]?.mesh
        lock.unlock()
        return value
    }

    public func reset() {
        lock.lock()
        meshCatalogRevision &+= 1
        projectRoot = nil
        entries.removeAll(keepingCapacity: true)
        meshes.removeAll(keepingCapacity: true)
        explicitlyRegisteredMeshes.removeAll(keepingCapacity: true)
        pathIndex.removeAll(keepingCapacity: true)
        nextMeshIndex = Self.importedMeshStartIndex
        lock.unlock()
    }

    /// Registers a mesh asset directly at the given index.
    /// Intended for unit tests that need a pre-built MeshAsset without loading from disk.
    public func registerForTesting(_ mesh: MeshAsset, at meshIndex: Int) {
        lock.lock()
        meshCatalogRevision &+= 1
        explicitlyRegisteredMeshes[meshIndex] = RegisteredMeshAsset(
            meshIndex: meshIndex,
            assetID: "test:\(meshIndex)",
            kind: .gltf,
            mesh: mesh
        )
        lock.unlock()
    }

    /// Removes one explicit mesh without disturbing the active project's
    /// catalog or any other transient registration.
    public func unregisterTestingMesh(at meshIndex: Int) {
        lock.lock()
        meshCatalogRevision &+= 1
        explicitlyRegisteredMeshes.removeValue(forKey: meshIndex)
        lock.unlock()
    }

    private static let buildDirectoryNames: Set<String> = [
        "build", ".build", "export", "node_modules", ".gradle",
    ]

    private static func relativePath(of candidate: URL, within root: URL) -> String? {
        guard PathIdentity.contains(candidate, in: root, includingRoot: false) else { return nil }
        return PathIdentity.relativePath(candidate, to: root)
    }

    private func findImportableAssets(in rootURL: URL) throws -> [(url: URL, kind: ImportableAssetKind)] {
        let files = try ProjectResourceWalker.files(in: rootURL) {
            Self.buildDirectoryNames.contains($0.lastPathComponent.lowercased())
        }
        var results: [(url: URL, kind: ImportableAssetKind)] = []
        for url in files {
            switch url.pathExtension.lowercased() {
            case "gltf":
                results.append((url, .gltf))
            case "glb":
                results.append((url, .glb))
            case "obj":
                results.append((url, .obj))
            case "dmesh":
                results.append((url, .dmesh))
            case "png":
                results.append((url, .png))
            case "jpg":
                results.append((url, .jpg))
            case "jpeg":
                results.append((url, .jpeg))
            case "webp":
                results.append((url, .webp))
            case "tga":
                results.append((url, .tga))
            case "bmp":
                results.append((url, .bmp))
            case "gif":
                results.append((url, .gif))
            case "svg":
                results.append((url, .svg))
            default:
                continue
            }
        }
        return results.sorted { $0.url.path < $1.url.path }
    }

    private func importMesh(at url: URL,
                            kind: ImportableAssetKind) throws -> (mesh: MeshAsset, topologySlices: [MeshTopologySlice]?) {
        switch kind {
        case .gltf, .glb:
            let loaded = try GLTFImporter.loadWithTopology(path: url.path)
            return (loaded.mesh, loaded.topologies)
        case .obj:
            return (try OBJLoader.load(path: url.path), nil)
        case .dmesh:
            let evaluated = try GeometryDocument.load(from: url).evaluate()
            return (evaluated.mesh, [evaluated.topologySlice])
        case .png, .jpg, .jpeg, .webp, .tga, .bmp, .gif, .svg:
            preconditionFailure("Texture assets are not mesh-importable")
        }
    }
}

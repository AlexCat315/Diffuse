import Foundation
import Logging
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
    case obj

    public var sceneKindLabel: String { "Static Mesh" }
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

    public init() {}

    @discardableResult
    public func loadProject(at rootPath: String) throws -> [AssetRegistryEntry] {
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true).resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AssetRegistryError.invalidProjectRoot(rootPath)
        }

        let candidates = try findImportableAssets(in: rootURL)
        var nextMeshIndex = Self.importedMeshStartIndex
        var loadedEntries: [AssetRegistryEntry] = []
        var loadedMeshes: [Int: RegisteredMeshAsset] = [:]

        for candidate in candidates {
            let kind = candidate.kind
            let imported: (mesh: MeshAsset, topologySlices: [MeshTopologySlice]?)
            do {
                imported = try importMesh(at: candidate.url, kind: kind)
            } catch {
                Logger(label: "com.guava.engine.assets").warning("AssetRegistry: skipping \(candidate.url.lastPathComponent) — \(error)")
                continue
            }
            var mesh = imported.mesh
            mesh.normalizeToUnitBounds(targetSize: 2.0)

            let normalizedSlices: [MeshTopologySlice]? = {
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

            let assetURL = candidate.url.resolvingSymlinksInPath()
            let rootPathWithSlash = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
            let relativePath = assetURL.path.replacingOccurrences(of: rootPathWithSlash, with: "")
            let entry = AssetRegistryEntry(
                id: relativePath,
                name: assetURL.deletingPathExtension().lastPathComponent,
                relativePath: relativePath,
                absolutePath: assetURL.path,
                kind: kind,
                meshIndex: nextMeshIndex
            )
            loadedEntries.append(entry)
            loadedMeshes[nextMeshIndex] = RegisteredMeshAsset(
                meshIndex: nextMeshIndex,
                assetID: entry.id,
                kind: kind,
                sourceDirectory: assetURL.deletingLastPathComponent().path,
                mesh: mesh,
                topologySlices: normalizedSlices
            )
            nextMeshIndex += 1
        }

        lock.lock()
        projectRoot = rootURL.path
        entries = loadedEntries
        meshes = loadedMeshes
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

    public func registeredMeshes() -> [RegisteredMeshAsset] {
        lock.lock()
        let value = meshes.values.sorted { $0.meshIndex < $1.meshIndex }
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
        let value = meshes[meshIndex]?.mesh
        lock.unlock()
        return value
    }

    public func reset() {
        lock.lock()
        projectRoot = nil
        entries.removeAll(keepingCapacity: true)
        meshes.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Registers a mesh asset directly at the given index.
    /// Intended for unit tests that need a pre-built MeshAsset without loading from disk.
    public func registerForTesting(_ mesh: MeshAsset, at meshIndex: Int) {
        lock.lock()
        meshes[meshIndex] = RegisteredMeshAsset(
            meshIndex: meshIndex,
            assetID: "test:\(meshIndex)",
            kind: .gltf,
            mesh: mesh
        )
        lock.unlock()
    }

    private static let buildDirectoryNames: Set<String> = ["build", ".build", "node_modules", ".gradle"]

    private func findImportableAssets(in rootURL: URL) throws -> [(url: URL, kind: ImportableAssetKind)] {
        let properties: [URLResourceKey] = [.isRegularFileKey, .isHiddenKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: rootURL,
                                                              includingPropertiesForKeys: properties,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return []
        }

        var results: [(url: URL, kind: ImportableAssetKind)] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(properties))
            if values.isDirectory == true {
                if Self.buildDirectoryNames.contains(url.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard values.isRegularFile == true else { continue }
            switch url.pathExtension.lowercased() {
            case "gltf":
                results.append((url, .gltf))
            case "obj":
                results.append((url, .obj))
            default:
                continue
            }
        }
        return results.sorted { $0.url.path < $1.url.path }
    }

    private func importMesh(at url: URL,
                            kind: ImportableAssetKind) throws -> (mesh: MeshAsset, topologySlices: [MeshTopologySlice]?) {
        switch kind {
        case .gltf:
            let loaded = try GLTFImporter.loadWithTopology(path: url.path)
            return (loaded.mesh, loaded.topologies)
        case .obj:
            return (try OBJLoader.load(path: url.path), nil)
        }
    }
}

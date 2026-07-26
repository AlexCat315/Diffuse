import AssetPipeline
import EditorCore
import Foundation

public enum GameProjectAssetIndexError: Error, CustomStringConvertible, Equatable {
    case missingExportAssetList
    case assetCountMismatch(expected: Int, actual: Int)
    case unsafeRelativePath(String)
    case duplicateRelativePath(String)
    case duplicateMeshIndex(Int)

    public var description: String {
        switch self {
        case .missingExportAssetList:
            return "project export is missing assets.json"
        case let .assetCountMismatch(expected, actual):
            return "project asset count mismatch (expected \(expected), found \(actual))"
        case let .unsafeRelativePath(path):
            return "export asset list contains an unsafe relative path: \(path)"
        case let .duplicateRelativePath(path):
            return "export asset list contains a duplicate relative path: \(path)"
        case let .duplicateMeshIndex(index):
            return "export asset list assigns mesh index \(index) more than once"
        }
    }
}

/// Loads the stable mesh-slot mapping recorded by ProjectExporter. A missing
/// asset list is valid for a development project, but an existing corrupt list
/// must not silently remap meshes and render the wrong scene.
public enum GameProjectAssetIndexLoader {
    public static func load(projectDirectory: URL,
                            fileManager: FileManager = .default) throws -> [String: Int] {
        let assetListURL = projectDirectory.appendingPathComponent("assets.json")
        let descriptorURL = projectDirectory.appendingPathComponent("build.json")
        let descriptor = fileManager.fileExists(atPath: descriptorURL.path)
            ? try ProjectExporter.readDescriptor(from: projectDirectory)
            : nil
        guard fileManager.fileExists(atPath: assetListURL.path) else {
            if descriptor != nil { throw GameProjectAssetIndexError.missingExportAssetList }
            return [:]
        }

        let data = try Data(contentsOf: assetListURL)
        let assetList = try JSONDecoder().decode(ProjectExportAssetList.self, from: data)
        if let descriptor,
           descriptor.assetCount != assetList.assets.count {
            throw GameProjectAssetIndexError.assetCountMismatch(
                expected: descriptor.assetCount,
                actual: assetList.assets.count
            )
        }
        var result: [String: Int] = [:]
        var seenRelativePaths = Set<String>()
        var usedMeshIndices = Set<Int>()
        for asset in assetList.assets {
            guard let relativePath = AssetImportResolver.sanitizedRelativePath(asset.relativePath) else {
                throw GameProjectAssetIndexError.unsafeRelativePath(asset.relativePath)
            }
            guard seenRelativePaths.insert(relativePath).inserted else {
                throw GameProjectAssetIndexError.duplicateRelativePath(relativePath)
            }
            // Texture entries use slot 0 and do not participate in the mesh map.
            guard asset.meshIndex >= AssetRegistry.importedMeshStartIndex else { continue }
            guard usedMeshIndices.insert(asset.meshIndex).inserted else {
                throw GameProjectAssetIndexError.duplicateMeshIndex(asset.meshIndex)
            }
            result[relativePath] = asset.meshIndex
        }
        return result
    }
}

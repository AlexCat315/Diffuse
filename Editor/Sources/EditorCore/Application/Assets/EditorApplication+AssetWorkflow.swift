import AssetPipeline
import Foundation

public struct EditorAssetReferenceLocation: Identifiable, Sendable {
    public let id: String
    public let label: String
    public let target: EditorIssueTarget
}

extension EditorApplication {
    public func assetReferences(_ asset: EditorAsset) -> [EditorAssetReferenceLocation] {
        let entities = scene.assetReferencedEntityIDs(asset.id).map { id in
            EditorAssetReferenceLocation(id: "entity:\(id)", label: scene.entitySummary(id: id)?.name ?? "\(id)", target: .entity(id: id))
        }
        let root = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        let files = EditorAssetFileWorkflow.referenceFiles(to: URL(fileURLWithPath: asset.absolutePath), within: root).map { url in
            EditorAssetReferenceLocation(id: url.path, label: EditorAssetFileWorkflow.relativePath(url, from: root), target: .file(path: url.path))
        }
        return entities + files
    }

    public func missingAssetPaths() -> [String] {
        var paths = Set(scene.missingAssetPaths())
        let root = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        for asset in EditorAssetCatalog.entries() {
            for file in AssetImportResolver.resolve(URL(fileURLWithPath: asset.absolutePath), projectRoot: root)
                where !FileManager.default.fileExists(atPath: file.source.path) { paths.insert(file.source.path) }
        }
        return paths.sorted()
    }

    @discardableResult
    public func relocateAsset(_ asset: EditorAsset, to relativePath: String) -> Bool {
        guard store.playbackState == .stopped else { return false }
        let root = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        let source = URL(fileURLWithPath: asset.absolutePath)
        let destination = root.appendingPathComponent(relativePath)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !scriptWorkspace.snapshot.documents.contains(where: { $0.isDirty && $0.source.contains(asset.relativePath) }) else {
            logConsole("Asset relocation blocked", severity: .warning, target: .asset(id: asset.id),
                       nextStep: "Enter a project-relative path and save scripts referencing this asset before moving it.")
            return false
        }
        do {
            _ = try EditorAssetFileWorkflow.relocate(from: source, to: destination, within: root)
            let newID = EditorAssetFileWorkflow.relativePath(destination, from: root)
            AssetRegistry.shared.relocateAssetPath(from: asset.id, to: newID)
            let moved: EditorAsset
            do {
                let assets = try EditorAssetCatalog.loadProject(at: projectDirectory)
                guard let candidate = assets.first(where: { $0.id == newID }) else {
                    throw EditorAssetFileWorkflow.Failure("The moved asset could not be indexed.")
                }
                moved = candidate
            }
            catch {
                _ = try EditorAssetFileWorkflow.relocate(from: destination, to: source, within: root)
                AssetRegistry.shared.relocateAssetPath(from: newID, to: asset.id)
                _ = try? EditorAssetCatalog.loadProject(at: projectDirectory)
                throw error
            }
            scene.relocateAssetReferences(from: asset.id, to: moved)
            scriptWorkspace.refreshFromDisk()
            store.dispatch(.navigateToAsset(moved.id))
            store.dispatch(.forceUIRefresh)
            logConsole("Asset relocated", detail: "\(asset.relativePath) → \(moved.relativePath)", target: .asset(id: moved.id))
            return true
        } catch {
            logConsole("Could not relocate asset", severity: .error, detail: String(describing: error),
                       target: .asset(id: asset.id), nextStep: "Check the destination, file permissions and dependencies, then retry.")
            return false
        }
    }

    @discardableResult
    public func repairMissingAsset(at path: String, from replacement: URL) -> Bool {
        guard store.playbackState == .stopped else { return false }
        let root = URL(fileURLWithPath: projectDirectory, isDirectory: true)
        let target = (path as NSString).isAbsolutePath ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        do {
            try EditorAssetFileWorkflow.restoreMissing(from: replacement, to: target, within: root) {
                guard reloadAssets() != nil else {
                    throw EditorAssetFileWorkflow.Failure("The restored file could not be indexed. Check its dependencies.")
                }
            }
            logConsole("Missing resource repaired", detail: target.path, target: .asset(id: EditorAssetFileWorkflow.relativePath(target, from: root)))
            return true
        } catch {
            _ = reloadAssets()
            logConsole("Could not repair missing resource", severity: .error, detail: String(describing: error),
                       target: .file(path: target.path), nextStep: "Select a valid file of the same format and check its dependencies.")
            return false
        }
    }
}

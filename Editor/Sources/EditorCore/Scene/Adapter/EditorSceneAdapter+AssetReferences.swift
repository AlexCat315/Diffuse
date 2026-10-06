import Foundation
import SceneRuntime

extension EditorSceneAdapter {
    public func assetReferencedEntityIDs(_ assetID: String) -> [UInt64] {
        var ids: Set<UInt64> = []
        for entity in scene.entities(with: AssetReferenceComponent.self) {
            if scene.component(AssetReferenceComponent.self, for: entity)?.assetID == assetID { ids.insert(entity.rawValue) }
        }
        for entity in scene.entities(with: RenderMeshComponent.self) {
            if scene.component(RenderMeshComponent.self, for: entity)?.assetID == assetID { ids.insert(entity.rawValue) }
        }
        for entity in scene.entities(with: ParticleEmitter.self) {
            if scene.component(ParticleEmitter.self, for: entity)?.textureAssetID == assetID { ids.insert(entity.rawValue) }
        }
        return ids.sorted()
    }

    public func missingAssetPaths() -> [String] {
        var paths: Set<String> = []
        for entity in scene.entities(with: AssetReferenceComponent.self) {
            if let asset = scene.component(AssetReferenceComponent.self, for: entity),
               !FileManager.default.fileExists(atPath: asset.absolutePath) { paths.insert(asset.absolutePath) }
        }
        for entity in scene.entities(with: ParticleEmitter.self) {
            if let path = scene.component(ParticleEmitter.self, for: entity)?.texturePath,
               !FileManager.default.fileExists(atPath: path) { paths.insert(path) }
        }
        return paths.sorted()
    }

    public func relocateAssetReferences(from oldID: String, to asset: EditorAsset) {
        func update(_ runtime: inout SceneRuntime) {
            for entity in runtime.entities(with: AssetReferenceComponent.self) {
                guard runtime.component(AssetReferenceComponent.self, for: entity)?.assetID == oldID else { continue }
                runtime.updateComponent(AssetReferenceComponent.self, for: entity) {
                    $0.assetID = asset.id; $0.name = asset.name; $0.relativePath = asset.relativePath
                    $0.absolutePath = asset.absolutePath; $0.meshIndex = asset.meshIndex
                }
            }
            for entity in runtime.entities(with: RenderMeshComponent.self) {
                guard runtime.component(RenderMeshComponent.self, for: entity)?.assetID == oldID else { continue }
                runtime.updateComponent(RenderMeshComponent.self, for: entity) { $0.assetID = asset.id; $0.meshIndex = asset.meshIndex }
            }
            for entity in runtime.entities(with: ParticleEmitter.self) {
                guard runtime.component(ParticleEmitter.self, for: entity)?.textureAssetID == oldID else { continue }
                runtime.updateComponent(ParticleEmitter.self, for: entity) { $0.textureAssetID = asset.id; $0.texturePath = asset.absolutePath }
            }
        }
        update(&scene)
        editHistory.remapScenes(update)
        notifyRevisionChanged(recordHistory: false)
    }
}

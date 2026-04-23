import Foundation
import IntentRuntime
import SceneRuntime
import simd

extension EditorSceneAdapter {
    /// 在场景里生成一个新实体并立即可见，返回 raw entity id。
    /// 调用方一般紧接着把返回的 id 写回 store 作为新的选中态。
    @discardableResult
    public func spawnEntity(from asset: EditorAsset,
                            at position: SIMD3<Float> = SIMD3<Float>(0, 0, 0)) -> UInt64? {
        let label = uniqueDisplayName(base: asset.name)
        let result = applySceneTransaction(intentVerb: "scene.spawn_entity",
                                           summary: "Spawn imported mesh entity",
                                           mutations: [
                                            .spawnImportedMeshEntity(label: label,
                                                                     kindLabel: asset.kind.sceneKindLabel,
                                                                     meshIndex: asset.meshIndex,
                                                                     position: position)
                                           ])
        return result?.createdEntityIDs.first
    }

    private func uniqueDisplayName(base: String) -> String {
        let existing: Set<String> = Set(scene.entities().compactMap {
            scene.component(SceneNameComponent.self, for: $0)?.value
        })
        if !existing.contains(base) { return base }
        var suffix = 2
        while existing.contains("\(base) \(suffix)") {
            suffix += 1
        }
        return "\(base) \(suffix)"
    }
}
